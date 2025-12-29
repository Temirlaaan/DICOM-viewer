#!/usr/bin/env python3
"""
=============================================================================
DICOM Importer Service
=============================================================================
Watches inbox folders for DICOM files and uploads them to Orthanc via STOW-RS.

Directory structure:
/inbox/
  {clinic_id}/              # Clinic identifier (maps to Keycloak group)
    {study_folder}/         # Study folder (e.g., PatientName_Date)
      *.dcm                 # DICOM files

Upon successful import:
- Files are moved to /processed/{clinic_id}/{YYYY-MM-DD}/{study_folder}/
- InstitutionName tag is set to clinic_id for access control

Upon failure:
- Files are moved to /failed/{clinic_id}/{YYYY-MM-DD}/{study_folder}/
- Error log file is created: {study_folder}.error.json
=============================================================================
"""

import os
import sys
import json
import time
import shutil
import signal
import logging
import hashlib
import threading
from pathlib import Path
from datetime import datetime
from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any
from concurrent.futures import ThreadPoolExecutor, as_completed

import pydicom
from pydicom.errors import InvalidDicomError
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler, FileCreatedEvent, DirCreatedEvent
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from prometheus_client import Counter, Histogram, Gauge, start_http_server
import structlog

# =============================================================================
# Configuration
# =============================================================================

@dataclass
class Config:
    """Application configuration from environment variables."""
    # Paths
    inbox_path: Path = field(default_factory=lambda: Path(os.getenv('INBOX_PATH', '/inbox')))
    processed_path: Path = field(default_factory=lambda: Path(os.getenv('PROCESSED_PATH', '/processed')))
    failed_path: Path = field(default_factory=lambda: Path(os.getenv('FAILED_PATH', '/failed')))

    # Orthanc connection
    orthanc_url: str = field(default_factory=lambda: os.getenv('ORTHANC_URL', 'http://orthanc:8042'))

    # Keycloak (for service account token)
    keycloak_url: str = field(default_factory=lambda: os.getenv('KEYCLOAK_URL', 'http://keycloak:8080'))
    keycloak_realm: str = field(default_factory=lambda: os.getenv('KEYCLOAK_REALM', 'dicom'))
    keycloak_client_id: str = field(default_factory=lambda: os.getenv('KEYCLOAK_CLIENT_ID', 'orthanc-api'))
    keycloak_client_secret: str = field(default_factory=lambda: os.getenv('KEYCLOAK_CLIENT_SECRET', ''))

    # Processing settings
    cooldown_seconds: int = field(default_factory=lambda: int(os.getenv('COOLDOWN_SECONDS', '60')))
    max_concurrent: int = field(default_factory=lambda: int(os.getenv('MAX_CONCURRENT', '3')))
    max_retries: int = field(default_factory=lambda: int(os.getenv('MAX_RETRIES', '3')))
    retry_delay: int = field(default_factory=lambda: int(os.getenv('RETRY_DELAY', '10')))

    # Logging
    log_level: str = field(default_factory=lambda: os.getenv('LOG_LEVEL', 'info').upper())
    log_format: str = field(default_factory=lambda: os.getenv('LOG_FORMAT', 'json'))

    # Metrics
    metrics_port: int = field(default_factory=lambda: int(os.getenv('METRICS_PORT', '8080')))

# =============================================================================
# Logging Setup
# =============================================================================

def setup_logging(config: Config) -> structlog.BoundLogger:
    """Configure structured logging."""
    structlog.configure(
        processors=[
            structlog.stdlib.filter_by_level,
            structlog.stdlib.add_logger_name,
            structlog.stdlib.add_log_level,
            structlog.stdlib.PositionalArgumentsFormatter(),
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.StackInfoRenderer(),
            structlog.processors.format_exc_info,
            structlog.processors.UnicodeDecoder(),
            structlog.processors.JSONRenderer() if config.log_format == 'json'
            else structlog.dev.ConsoleRenderer(),
        ],
        context_class=dict,
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
        cache_logger_on_first_use=True,
    )

    logging.basicConfig(
        format="%(message)s",
        stream=sys.stdout,
        level=getattr(logging, config.log_level),
    )

    return structlog.get_logger()

# =============================================================================
# Prometheus Metrics
# =============================================================================

# Counters
IMPORTS_TOTAL = Counter(
    'dicom_imports_total',
    'Total number of DICOM import attempts',
    ['clinic_id', 'status']
)

INSTANCES_UPLOADED = Counter(
    'dicom_instances_uploaded_total',
    'Total number of DICOM instances uploaded',
    ['clinic_id']
)

# Histograms
IMPORT_DURATION = Histogram(
    'dicom_import_duration_seconds',
    'Time spent importing a study',
    ['clinic_id'],
    buckets=(5, 10, 30, 60, 120, 300, 600, 1800)
)

UPLOAD_DURATION = Histogram(
    'dicom_upload_duration_seconds',
    'Time spent uploading a single DICOM file',
    buckets=(0.1, 0.5, 1, 2, 5, 10, 30)
)

# Gauges
PENDING_IMPORTS = Gauge(
    'dicom_pending_imports',
    'Number of studies waiting to be imported'
)

ACTIVE_IMPORTS = Gauge(
    'dicom_active_imports',
    'Number of studies currently being imported'
)

# =============================================================================
# Token Manager
# =============================================================================

class TokenManager:
    """Manages Keycloak service account tokens."""

    def __init__(self, config: Config, logger: structlog.BoundLogger):
        self.config = config
        self.logger = logger
        self._token: Optional[str] = None
        self._token_expires: float = 0
        self._lock = threading.Lock()

    def get_token(self) -> Optional[str]:
        """Get a valid access token, refreshing if necessary."""
        with self._lock:
            if self._token and time.time() < self._token_expires - 60:
                return self._token

            return self._refresh_token()

    def _refresh_token(self) -> Optional[str]:
        """Refresh the access token from Keycloak."""
        if not self.config.keycloak_client_secret:
            self.logger.debug("No client secret configured, skipping token refresh")
            return None

        token_url = (
            f"{self.config.keycloak_url}/realms/{self.config.keycloak_realm}"
            f"/protocol/openid-connect/token"
        )

        try:
            response = requests.post(
                token_url,
                data={
                    'grant_type': 'client_credentials',
                    'client_id': self.config.keycloak_client_id,
                    'client_secret': self.config.keycloak_client_secret,
                },
                timeout=30
            )
            response.raise_for_status()

            data = response.json()
            self._token = data['access_token']
            self._token_expires = time.time() + data.get('expires_in', 300)

            self.logger.debug("Token refreshed successfully")
            return self._token

        except Exception as e:
            self.logger.error("Failed to refresh token", error=str(e))
            return None

# =============================================================================
# DICOM Processor
# =============================================================================

class DicomProcessor:
    """Processes and uploads DICOM files to Orthanc."""

    def __init__(self, config: Config, token_manager: TokenManager,
                 logger: structlog.BoundLogger):
        self.config = config
        self.token_manager = token_manager
        self.logger = logger

        # HTTP session with retry logic
        self.session = requests.Session()
        retry_strategy = Retry(
            total=config.max_retries,
            backoff_factor=config.retry_delay,
            status_forcelist=[429, 500, 502, 503, 504],
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        self.session.mount("http://", adapter)
        self.session.mount("https://", adapter)

    def process_study_folder(self, study_path: Path, clinic_id: str) -> bool:
        """Process all DICOM files in a study folder."""
        log = self.logger.bind(study_path=str(study_path), clinic_id=clinic_id)

        start_time = time.time()
        ACTIVE_IMPORTS.inc()

        try:
            # Find all DICOM files
            dicom_files = list(study_path.glob('**/*.dcm')) + list(study_path.glob('**/*.DCM'))

            # Also try files without extension (some DICOM files don't have .dcm)
            for file_path in study_path.glob('**/*'):
                if file_path.is_file() and file_path.suffix.lower() not in ['.dcm', '.json', '.txt', '.log']:
                    try:
                        pydicom.dcmread(file_path, stop_before_pixels=True)
                        if file_path not in dicom_files:
                            dicom_files.append(file_path)
                    except Exception:
                        pass

            if not dicom_files:
                log.warning("No DICOM files found in study folder")
                self._move_to_failed(study_path, clinic_id, "No DICOM files found")
                IMPORTS_TOTAL.labels(clinic_id=clinic_id, status='failed').inc()
                return False

            log.info(f"Found {len(dicom_files)} DICOM files")

            # Process each file
            success_count = 0
            error_count = 0
            errors = []

            for dicom_file in dicom_files:
                try:
                    self._process_single_file(dicom_file, clinic_id)
                    success_count += 1
                    INSTANCES_UPLOADED.labels(clinic_id=clinic_id).inc()
                except Exception as e:
                    error_count += 1
                    errors.append({
                        'file': str(dicom_file.relative_to(study_path)),
                        'error': str(e)
                    })
                    log.error("Failed to process file", file=str(dicom_file), error=str(e))

            # Determine overall success
            if error_count == 0:
                log.info("Study imported successfully",
                        files_processed=success_count)
                self._move_to_processed(study_path, clinic_id)
                IMPORTS_TOTAL.labels(clinic_id=clinic_id, status='success').inc()
                return True
            elif success_count > 0:
                log.warning("Study partially imported",
                           success_count=success_count, error_count=error_count)
                self._move_to_processed(study_path, clinic_id)
                IMPORTS_TOTAL.labels(clinic_id=clinic_id, status='partial').inc()
                return True
            else:
                log.error("Study import failed completely",
                         error_count=error_count)
                self._move_to_failed(study_path, clinic_id,
                                    f"All {error_count} files failed", errors)
                IMPORTS_TOTAL.labels(clinic_id=clinic_id, status='failed').inc()
                return False

        except Exception as e:
            log.exception("Unexpected error processing study")
            self._move_to_failed(study_path, clinic_id, str(e))
            IMPORTS_TOTAL.labels(clinic_id=clinic_id, status='error').inc()
            return False

        finally:
            duration = time.time() - start_time
            IMPORT_DURATION.labels(clinic_id=clinic_id).observe(duration)
            ACTIVE_IMPORTS.dec()

    def _process_single_file(self, file_path: Path, clinic_id: str) -> None:
        """Process and upload a single DICOM file."""
        start_time = time.time()

        # Read DICOM file
        try:
            ds = pydicom.dcmread(file_path)
        except InvalidDicomError as e:
            raise ValueError(f"Invalid DICOM file: {e}")

        # Modify InstitutionName for access control
        ds.InstitutionName = clinic_id

        # Add custom private tag for import tracking
        # ds.add_new((0x0099, 0x0001), 'LO', datetime.now().isoformat())

        # Serialize to bytes
        from io import BytesIO
        buffer = BytesIO()
        ds.save_as(buffer)
        dicom_bytes = buffer.getvalue()

        # Upload via STOW-RS
        self._upload_stow_rs(dicom_bytes, file_path.name)

        UPLOAD_DURATION.observe(time.time() - start_time)

    def _upload_stow_rs(self, dicom_bytes: bytes, filename: str) -> None:
        """Upload DICOM data to Orthanc via STOW-RS."""
        stow_url = f"{self.config.orthanc_url}/dicom-web/studies"

        # Build multipart message
        boundary = hashlib.md5(str(time.time()).encode()).hexdigest()

        body = (
            f'--{boundary}\r\n'
            f'Content-Type: application/dicom\r\n'
            f'Content-Disposition: attachment; filename="{filename}"\r\n\r\n'
        ).encode('utf-8') + dicom_bytes + f'\r\n--{boundary}--\r\n'.encode('utf-8')

        headers = {
            'Content-Type': f'multipart/related; type="application/dicom"; boundary={boundary}',
            'Accept': 'application/dicom+json',
        }

        # Add authorization if available
        token = self.token_manager.get_token()
        if token:
            headers['Authorization'] = f'Bearer {token}'

        response = self.session.post(stow_url, data=body, headers=headers, timeout=120)

        if response.status_code not in [200, 202]:
            raise Exception(f"STOW-RS failed: {response.status_code} - {response.text[:500]}")

    def _move_to_processed(self, study_path: Path, clinic_id: str) -> None:
        """Move processed study to the processed directory."""
        date_str = datetime.now().strftime('%Y-%m-%d')
        dest_dir = self.config.processed_path / clinic_id / date_str
        dest_dir.mkdir(parents=True, exist_ok=True)

        dest_path = dest_dir / study_path.name
        if dest_path.exists():
            # Add timestamp if destination exists
            timestamp = datetime.now().strftime('%H%M%S')
            dest_path = dest_dir / f"{study_path.name}_{timestamp}"

        shutil.move(str(study_path), str(dest_path))
        self.logger.info("Study moved to processed", destination=str(dest_path))

    def _move_to_failed(self, study_path: Path, clinic_id: str,
                        reason: str, errors: List[Dict] = None) -> None:
        """Move failed study to the failed directory."""
        date_str = datetime.now().strftime('%Y-%m-%d')
        dest_dir = self.config.failed_path / clinic_id / date_str
        dest_dir.mkdir(parents=True, exist_ok=True)

        dest_path = dest_dir / study_path.name
        if dest_path.exists():
            timestamp = datetime.now().strftime('%H%M%S')
            dest_path = dest_dir / f"{study_path.name}_{timestamp}"

        shutil.move(str(study_path), str(dest_path))

        # Create error log file
        error_log = {
            'timestamp': datetime.now().isoformat(),
            'study_folder': study_path.name,
            'clinic_id': clinic_id,
            'reason': reason,
            'errors': errors or []
        }

        error_file = dest_path.parent / f"{dest_path.name}.error.json"
        with open(error_file, 'w') as f:
            json.dump(error_log, f, indent=2)

        self.logger.warning("Study moved to failed", destination=str(dest_path), reason=reason)

# =============================================================================
# File Watcher
# =============================================================================

class InboxHandler(FileSystemEventHandler):
    """Handles file system events in the inbox directory."""

    def __init__(self, config: Config, processor: DicomProcessor,
                 logger: structlog.BoundLogger):
        self.config = config
        self.processor = processor
        self.logger = logger
        self.pending_folders: Dict[str, float] = {}
        self._lock = threading.Lock()
        self._executor = ThreadPoolExecutor(max_workers=config.max_concurrent)

    def on_created(self, event):
        """Handle file/directory creation events."""
        if isinstance(event, DirCreatedEvent):
            self._handle_new_folder(Path(event.src_path))
        elif isinstance(event, FileCreatedEvent):
            # When a file is created, check its parent folder
            parent = Path(event.src_path).parent
            self._handle_new_folder(parent)

    def on_modified(self, event):
        """Handle file modification events (file write completion)."""
        if not event.is_directory:
            parent = Path(event.src_path).parent
            self._handle_new_folder(parent)

    def _handle_new_folder(self, folder_path: Path) -> None:
        """Handle a potentially new study folder."""
        # Determine clinic_id from path
        try:
            relative = folder_path.relative_to(self.config.inbox_path)
            parts = relative.parts

            if len(parts) < 2:
                return  # Not a study folder yet

            clinic_id = parts[0]
            study_folder = self.config.inbox_path / clinic_id / parts[1]

        except ValueError:
            return

        # Add to pending with cooldown timer
        folder_key = str(study_folder)
        with self._lock:
            self.pending_folders[folder_key] = time.time()
            PENDING_IMPORTS.set(len(self.pending_folders))

        self.logger.debug("Folder added to pending",
                         folder=folder_key, clinic_id=clinic_id)

    def check_pending_folders(self) -> None:
        """Check pending folders and process those past cooldown."""
        now = time.time()
        folders_to_process = []

        with self._lock:
            for folder_key, timestamp in list(self.pending_folders.items()):
                if now - timestamp >= self.config.cooldown_seconds:
                    folders_to_process.append(folder_key)
                    del self.pending_folders[folder_key]

            PENDING_IMPORTS.set(len(self.pending_folders))

        # Process folders
        for folder_key in folders_to_process:
            folder_path = Path(folder_key)

            if not folder_path.exists():
                self.logger.debug("Folder no longer exists", folder=folder_key)
                continue

            # Extract clinic_id
            try:
                relative = folder_path.relative_to(self.config.inbox_path)
                clinic_id = relative.parts[0]
            except (ValueError, IndexError):
                continue

            self.logger.info("Processing study folder",
                           folder=folder_key, clinic_id=clinic_id)

            # Submit to executor
            self._executor.submit(
                self.processor.process_study_folder,
                folder_path,
                clinic_id
            )

    def shutdown(self) -> None:
        """Shutdown the executor."""
        self._executor.shutdown(wait=True)

# =============================================================================
# Health Check Server
# =============================================================================

def create_health_app(config: Config, logger: structlog.BoundLogger):
    """Create Flask app for health checks and metrics."""
    from flask import Flask, jsonify

    app = Flask(__name__)

    @app.route('/health')
    def health():
        """Health check endpoint."""
        # Check Orthanc connectivity
        try:
            response = requests.get(f"{config.orthanc_url}/system", timeout=5)
            orthanc_healthy = response.status_code == 200
        except Exception:
            orthanc_healthy = False

        status = 'healthy' if orthanc_healthy else 'degraded'
        return jsonify({
            'status': status,
            'timestamp': datetime.now().isoformat(),
            'checks': {
                'orthanc': orthanc_healthy
            }
        }), 200 if orthanc_healthy else 503

    @app.route('/ready')
    def ready():
        """Readiness check endpoint."""
        return jsonify({'status': 'ready'}), 200

    return app

# =============================================================================
# Main Application
# =============================================================================

def main():
    """Main entry point."""
    config = Config()
    logger = setup_logging(config)

    logger.info("Starting DICOM Importer",
                inbox_path=str(config.inbox_path),
                orthanc_url=config.orthanc_url)

    # Ensure directories exist
    config.inbox_path.mkdir(parents=True, exist_ok=True)
    config.processed_path.mkdir(parents=True, exist_ok=True)
    config.failed_path.mkdir(parents=True, exist_ok=True)

    # Start Prometheus metrics server
    start_http_server(config.metrics_port)
    logger.info(f"Metrics server started on port {config.metrics_port}")

    # Initialize components
    token_manager = TokenManager(config, logger)
    processor = DicomProcessor(config, token_manager, logger)
    handler = InboxHandler(config, processor, logger)

    # Set up file watcher
    observer = Observer()
    observer.schedule(handler, str(config.inbox_path), recursive=True)
    observer.start()
    logger.info("File watcher started")

    # Signal handling
    shutdown_event = threading.Event()

    def signal_handler(signum, frame):
        logger.info("Shutdown signal received")
        shutdown_event.set()

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    # Scan for existing files on startup
    for clinic_dir in config.inbox_path.iterdir():
        if clinic_dir.is_dir():
            for study_dir in clinic_dir.iterdir():
                if study_dir.is_dir():
                    handler._handle_new_folder(study_dir)

    # Main loop
    try:
        while not shutdown_event.is_set():
            handler.check_pending_folders()
            shutdown_event.wait(timeout=5)

    except Exception as e:
        logger.exception("Unexpected error in main loop")

    finally:
        logger.info("Shutting down...")
        observer.stop()
        observer.join()
        handler.shutdown()
        logger.info("Shutdown complete")

if __name__ == '__main__':
    main()
