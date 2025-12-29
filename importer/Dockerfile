# =============================================================================
# DICOM Importer Service
# =============================================================================
# Python-based file watcher that monitors inbox folders and uploads
# DICOM files to Orthanc via STOW-RS
# =============================================================================

FROM python:3.12-slim

# Labels
LABEL maintainer="DICOM Stack Admin"
LABEL version="1.0.0"
LABEL description="DICOM file watcher and importer service"

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd --gid 1000 importer && \
    useradd --uid 1000 --gid 1000 --create-home importer

# Set working directory
WORKDIR /app

# Copy requirements first for better caching
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY importer.py .
COPY config.yaml.example .

# Create directories
RUN mkdir -p /var/log/importer && \
    chown -R importer:importer /app /var/log/importer

# Switch to non-root user
USER importer

# Health check
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Expose metrics/health port
EXPOSE 8080

# Run the importer
CMD ["python", "-u", "importer.py"]
