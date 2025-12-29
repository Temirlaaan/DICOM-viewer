# =============================================================================
# Orthanc DICOM Server with Plugins
# =============================================================================
# Based on official Orthanc image with additional plugins for:
# - PostgreSQL storage
# - DICOMweb API
# - Authorization (JWT validation)
# =============================================================================

FROM orthancteam/orthanc:24.6.2

# Labels
LABEL maintainer="DICOM Stack Admin"
LABEL version="1.0.0"
LABEL description="Orthanc DICOM Server with PostgreSQL, DICOMweb, and Authorization plugins"

# Install additional tools
USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    lua5.4 \
    lua-socket \
    lua-sec \
    lua-cjson \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /etc/orthanc/scripts /var/lib/orthanc/db

# Copy configuration
COPY orthanc.json /etc/orthanc/orthanc.json
COPY scripts/ /etc/orthanc/scripts/

# Set permissions
RUN chown -R orthanc:orthanc /etc/orthanc /var/lib/orthanc

# Switch back to orthanc user
USER orthanc

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8042/system || exit 1

# Expose ports
# 8042 - HTTP REST API
# 4242 - DICOM protocol
EXPOSE 8042 4242

# Entry point (from base image)
CMD ["Orthanc", "/etc/orthanc/orthanc.json"]
