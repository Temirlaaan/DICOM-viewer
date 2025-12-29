#!/usr/bin/env python3
"""
=============================================================================
Tests for DICOM Importer Service
=============================================================================
"""

import os
import sys
import json
import tempfile
import shutil
from pathlib import Path
from unittest.mock import Mock, patch, MagicMock
from io import BytesIO

import pytest
import responses
import pydicom
from pydicom.dataset import Dataset, FileDataset
from pydicom.uid import ExplicitVRLittleEndian

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from importer import Config, TokenManager, DicomProcessor, InboxHandler

# =============================================================================
# Fixtures
# =============================================================================

@pytest.fixture
def temp_dirs():
    """Create temporary directories for testing."""
    base_dir = tempfile.mkdtemp()
    dirs = {
        'inbox': Path(base_dir) / 'inbox',
        'processed': Path(base_dir) / 'processed',
        'failed': Path(base_dir) / 'failed',
    }
    for d in dirs.values():
        d.mkdir(parents=True)

    yield dirs

    # Cleanup
    shutil.rmtree(base_dir)

@pytest.fixture
def config(temp_dirs):
    """Create test configuration."""
    return Config(
        inbox_path=temp_dirs['inbox'],
        processed_path=temp_dirs['processed'],
        failed_path=temp_dirs['failed'],
        orthanc_url='http://localhost:8042',
        keycloak_url='http://localhost:8080',
        keycloak_realm='dicom',
        keycloak_client_id='orthanc-api',
        keycloak_client_secret='test-secret',
        cooldown_seconds=1,
        max_concurrent=2,
        max_retries=2,
        retry_delay=1,
        log_level='DEBUG',
        log_format='console',
        metrics_port=9999,
    )

@pytest.fixture
def mock_logger():
    """Create mock logger."""
    logger = MagicMock()
    logger.bind.return_value = logger
    return logger

@pytest.fixture
def token_manager(config, mock_logger):
    """Create token manager."""
    return TokenManager(config, mock_logger)

@pytest.fixture
def processor(config, token_manager, mock_logger):
    """Create DICOM processor."""
    return DicomProcessor(config, token_manager, mock_logger)

def create_test_dicom(patient_name="Test^Patient", study_date="20240101"):
    """Create a minimal test DICOM dataset."""
    file_meta = pydicom.Dataset()
    file_meta.MediaStorageSOPClassUID = '1.2.840.10008.5.1.4.1.1.2'
    file_meta.MediaStorageSOPInstanceUID = pydicom.uid.generate_uid()
    file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    file_meta.ImplementationClassUID = pydicom.uid.generate_uid()

    ds = FileDataset(None, {}, file_meta=file_meta, preamble=b'\x00' * 128)

    ds.PatientName = patient_name
    ds.PatientID = "TEST001"
    ds.StudyDate = study_date
    ds.StudyInstanceUID = pydicom.uid.generate_uid()
    ds.SeriesInstanceUID = pydicom.uid.generate_uid()
    ds.SOPInstanceUID = file_meta.MediaStorageSOPInstanceUID
    ds.SOPClassUID = file_meta.MediaStorageSOPClassUID
    ds.Modality = "CT"
    ds.InstitutionName = "Original Hospital"

    # Add required elements
    ds.is_little_endian = True
    ds.is_implicit_VR = False

    return ds

# =============================================================================
# Config Tests
# =============================================================================

class TestConfig:
    def test_default_values(self):
        """Test default configuration values."""
        config = Config()
        assert config.inbox_path == Path('/inbox')
        assert config.cooldown_seconds == 60
        assert config.max_concurrent == 3

    def test_environment_override(self, monkeypatch):
        """Test configuration from environment variables."""
        monkeypatch.setenv('INBOX_PATH', '/custom/inbox')
        monkeypatch.setenv('COOLDOWN_SECONDS', '120')

        config = Config()
        assert config.inbox_path == Path('/custom/inbox')
        assert config.cooldown_seconds == 120

# =============================================================================
# TokenManager Tests
# =============================================================================

class TestTokenManager:
    @responses.activate
    def test_get_token_success(self, token_manager, config):
        """Test successful token retrieval."""
        token_url = f"{config.keycloak_url}/realms/{config.keycloak_realm}/protocol/openid-connect/token"

        responses.add(
            responses.POST,
            token_url,
            json={
                'access_token': 'test-token-123',
                'expires_in': 300,
                'token_type': 'Bearer',
            },
            status=200
        )

        token = token_manager.get_token()
        assert token == 'test-token-123'

    @responses.activate
    def test_get_token_cached(self, token_manager, config):
        """Test token caching."""
        token_url = f"{config.keycloak_url}/realms/{config.keycloak_realm}/protocol/openid-connect/token"

        responses.add(
            responses.POST,
            token_url,
            json={
                'access_token': 'test-token-123',
                'expires_in': 300,
            },
            status=200
        )

        # First call
        token1 = token_manager.get_token()
        # Second call should use cache
        token2 = token_manager.get_token()

        assert token1 == token2
        assert len(responses.calls) == 1  # Only one request made

    def test_get_token_no_secret(self, config, mock_logger):
        """Test token retrieval without client secret."""
        config.keycloak_client_secret = ''
        manager = TokenManager(config, mock_logger)

        token = manager.get_token()
        assert token is None

# =============================================================================
# DicomProcessor Tests
# =============================================================================

class TestDicomProcessor:
    def test_process_single_file(self, processor, temp_dirs):
        """Test processing a single DICOM file."""
        # Create test DICOM file
        clinic_id = 'test-clinic'
        study_dir = temp_dirs['inbox'] / clinic_id / 'test_study'
        study_dir.mkdir(parents=True)

        ds = create_test_dicom()
        dicom_path = study_dir / 'test.dcm'
        ds.save_as(str(dicom_path))

        # Mock the upload
        with patch.object(processor, '_upload_stow_rs') as mock_upload:
            processor._process_single_file(dicom_path, clinic_id)

            # Verify upload was called
            mock_upload.assert_called_once()

            # Verify the DICOM was modified
            call_args = mock_upload.call_args[0]
            uploaded_bytes = call_args[0]

            # Parse uploaded DICOM
            uploaded_ds = pydicom.dcmread(BytesIO(uploaded_bytes))
            assert uploaded_ds.InstitutionName == clinic_id

    @responses.activate
    def test_upload_stow_rs_success(self, processor, config):
        """Test successful STOW-RS upload."""
        stow_url = f"{config.orthanc_url}/dicom-web/studies"

        responses.add(
            responses.POST,
            stow_url,
            json={'status': 'success'},
            status=200
        )

        ds = create_test_dicom()
        buffer = BytesIO()
        ds.save_as(buffer)

        # Should not raise
        processor._upload_stow_rs(buffer.getvalue(), 'test.dcm')

    @responses.activate
    def test_upload_stow_rs_failure(self, processor, config):
        """Test STOW-RS upload failure."""
        stow_url = f"{config.orthanc_url}/dicom-web/studies"

        responses.add(
            responses.POST,
            stow_url,
            json={'error': 'Server error'},
            status=500
        )

        ds = create_test_dicom()
        buffer = BytesIO()
        ds.save_as(buffer)

        with pytest.raises(Exception) as exc_info:
            processor._upload_stow_rs(buffer.getvalue(), 'test.dcm')

        assert 'STOW-RS failed' in str(exc_info.value)

    def test_move_to_processed(self, processor, temp_dirs):
        """Test moving study to processed directory."""
        clinic_id = 'test-clinic'
        study_dir = temp_dirs['inbox'] / clinic_id / 'test_study'
        study_dir.mkdir(parents=True)
        (study_dir / 'test.dcm').touch()

        processor._move_to_processed(study_dir, clinic_id)

        # Verify original is gone
        assert not study_dir.exists()

        # Verify moved to processed
        processed_dirs = list(temp_dirs['processed'].glob('**/test_study'))
        assert len(processed_dirs) == 1

    def test_move_to_failed(self, processor, temp_dirs):
        """Test moving study to failed directory with error log."""
        clinic_id = 'test-clinic'
        study_dir = temp_dirs['inbox'] / clinic_id / 'test_study'
        study_dir.mkdir(parents=True)
        (study_dir / 'test.dcm').touch()

        errors = [{'file': 'test.dcm', 'error': 'Test error'}]
        processor._move_to_failed(study_dir, clinic_id, 'Test failure', errors)

        # Verify original is gone
        assert not study_dir.exists()

        # Verify moved to failed
        failed_dirs = list(temp_dirs['failed'].glob('**/test_study'))
        assert len(failed_dirs) == 1

        # Verify error log created
        error_files = list(temp_dirs['failed'].glob('**/*.error.json'))
        assert len(error_files) == 1

        with open(error_files[0]) as f:
            error_data = json.load(f)

        assert error_data['reason'] == 'Test failure'
        assert error_data['clinic_id'] == clinic_id
        assert len(error_data['errors']) == 1

    @responses.activate
    def test_process_study_folder_success(self, processor, config, temp_dirs):
        """Test full study folder processing."""
        stow_url = f"{config.orthanc_url}/dicom-web/studies"

        responses.add(
            responses.POST,
            stow_url,
            json={'status': 'success'},
            status=200
        )

        # Create test study
        clinic_id = 'test-clinic'
        study_dir = temp_dirs['inbox'] / clinic_id / 'test_study'
        study_dir.mkdir(parents=True)

        ds = create_test_dicom()
        ds.save_as(str(study_dir / 'test.dcm'))

        result = processor.process_study_folder(study_dir, clinic_id)

        assert result is True
        assert not study_dir.exists()

        # Verify in processed
        processed_dirs = list(temp_dirs['processed'].glob('**/test_study'))
        assert len(processed_dirs) == 1

    def test_process_study_folder_no_dicom(self, processor, temp_dirs):
        """Test processing folder with no DICOM files."""
        clinic_id = 'test-clinic'
        study_dir = temp_dirs['inbox'] / clinic_id / 'test_study'
        study_dir.mkdir(parents=True)
        (study_dir / 'readme.txt').touch()

        result = processor.process_study_folder(study_dir, clinic_id)

        assert result is False

        # Verify in failed
        failed_dirs = list(temp_dirs['failed'].glob('**/test_study'))
        assert len(failed_dirs) == 1

# =============================================================================
# InboxHandler Tests
# =============================================================================

class TestInboxHandler:
    def test_handle_new_folder(self, config, processor, mock_logger, temp_dirs):
        """Test handling new folder creation."""
        handler = InboxHandler(config, processor, mock_logger)

        clinic_id = 'test-clinic'
        study_dir = temp_dirs['inbox'] / clinic_id / 'test_study'
        study_dir.mkdir(parents=True)

        handler._handle_new_folder(study_dir)

        assert len(handler.pending_folders) == 1
        assert str(study_dir) in handler.pending_folders

        handler.shutdown()

    def test_check_pending_folders(self, config, processor, mock_logger, temp_dirs):
        """Test checking and processing pending folders."""
        config.cooldown_seconds = 0  # Immediate processing
        handler = InboxHandler(config, processor, mock_logger)

        clinic_id = 'test-clinic'
        study_dir = temp_dirs['inbox'] / clinic_id / 'test_study'
        study_dir.mkdir(parents=True)

        # Create a DICOM file
        ds = create_test_dicom()
        ds.save_as(str(study_dir / 'test.dcm'))

        handler._handle_new_folder(study_dir)

        with patch.object(processor, 'process_study_folder') as mock_process:
            mock_process.return_value = True
            handler.check_pending_folders()

            # Wait for executor
            handler.shutdown()

            mock_process.assert_called_once_with(study_dir, clinic_id)

# =============================================================================
# Integration Tests
# =============================================================================

class TestIntegration:
    @responses.activate
    def test_full_workflow(self, config, temp_dirs):
        """Test complete import workflow."""
        from importer import setup_logging, TokenManager, DicomProcessor

        # Mock endpoints
        token_url = f"{config.keycloak_url}/realms/{config.keycloak_realm}/protocol/openid-connect/token"
        stow_url = f"{config.orthanc_url}/dicom-web/studies"

        responses.add(
            responses.POST,
            token_url,
            json={'access_token': 'test-token', 'expires_in': 300},
            status=200
        )

        responses.add(
            responses.POST,
            stow_url,
            json={'status': 'success'},
            status=200
        )

        # Setup
        logger = MagicMock()
        logger.bind.return_value = logger

        token_manager = TokenManager(config, logger)
        processor = DicomProcessor(config, token_manager, logger)

        # Create test study
        clinic_id = 'integration-clinic'
        study_dir = temp_dirs['inbox'] / clinic_id / 'integration_study'
        study_dir.mkdir(parents=True)

        # Create multiple DICOM files
        for i in range(3):
            ds = create_test_dicom(f"Patient^{i}")
            ds.save_as(str(study_dir / f'test_{i}.dcm'))

        # Process
        result = processor.process_study_folder(study_dir, clinic_id)

        assert result is True
        assert not study_dir.exists()

        # Verify all files were uploaded
        stow_calls = [c for c in responses.calls if 'dicom-web/studies' in c.request.url]
        assert len(stow_calls) == 3

if __name__ == '__main__':
    pytest.main([__file__, '-v'])
