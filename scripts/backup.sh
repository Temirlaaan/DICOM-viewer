#!/bin/bash
# =============================================================================
# DICOM Web Viewer Stack - Backup Script
# =============================================================================
# Creates backups of:
# - PostgreSQL databases (Orthanc + Keycloak)
# - DICOM storage (optional, incremental)
# - Configuration files
# - Keycloak realm export
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load environment
if [[ -f "$PROJECT_DIR/.env" ]]; then
    source "$PROJECT_DIR/.env"
fi

# Configuration
BACKUP_DIR="${BACKUP_PATH:-/backup}"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_NAME="dicom-backup-$TIMESTAMP"
CURRENT_BACKUP="$BACKUP_DIR/$BACKUP_NAME"

# Retention settings
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=12

# Log functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse arguments
INCLUDE_DICOM=false
INCLUDE_REALM=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --include-dicom)
            INCLUDE_DICOM=true
            shift
            ;;
        --no-realm)
            INCLUDE_REALM=false
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --include-dicom   Include DICOM storage in backup (large!)"
            echo "  --no-realm        Skip Keycloak realm export"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Create backup directory
create_backup_dir() {
    log_info "Creating backup directory: $CURRENT_BACKUP"
    mkdir -p "$CURRENT_BACKUP"
    mkdir -p "$CURRENT_BACKUP/postgres"
    mkdir -p "$CURRENT_BACKUP/config"
}

# Backup PostgreSQL databases
backup_postgres() {
    log_info "Backing up PostgreSQL databases..."

    # Check if postgres container is running
    if ! docker compose -f "$PROJECT_DIR/docker-compose.yml" ps postgres | grep -q "running"; then
        log_error "PostgreSQL container is not running"
        return 1
    fi

    # Backup Orthanc database
    log_info "  - Backing up Orthanc database..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T postgres \
        pg_dump -U "${POSTGRES_USER:-dicom}" -d "${POSTGRES_DB:-orthanc}" \
        > "$CURRENT_BACKUP/postgres/orthanc.sql"

    # Backup Keycloak database
    log_info "  - Backing up Keycloak database..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T postgres \
        pg_dump -U "${POSTGRES_USER:-dicom}" -d keycloak \
        > "$CURRENT_BACKUP/postgres/keycloak.sql"

    # Compress backups
    gzip "$CURRENT_BACKUP/postgres/orthanc.sql"
    gzip "$CURRENT_BACKUP/postgres/keycloak.sql"

    log_success "PostgreSQL backups completed."
}

# Export Keycloak realm
backup_keycloak_realm() {
    if [[ "$INCLUDE_REALM" != "true" ]]; then
        log_info "Skipping Keycloak realm export."
        return
    fi

    log_info "Exporting Keycloak realm..."

    # Check if keycloak container is running
    if ! docker compose -f "$PROJECT_DIR/docker-compose.yml" ps keycloak | grep -q "running"; then
        log_warn "Keycloak container is not running, skipping realm export"
        return
    fi

    # Export realm
    docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T keycloak \
        /opt/keycloak/bin/kc.sh export \
        --dir /tmp/export \
        --realm dicom \
        --users realm_file 2>/dev/null || true

    # Copy export
    docker compose -f "$PROJECT_DIR/docker-compose.yml" cp \
        keycloak:/tmp/export/dicom-realm.json \
        "$CURRENT_BACKUP/keycloak-realm.json" 2>/dev/null || \
        log_warn "Could not export Keycloak realm"

    log_success "Keycloak realm export completed."
}

# Backup configuration files
backup_config() {
    log_info "Backing up configuration files..."

    # Copy configuration files
    cp "$PROJECT_DIR/.env" "$CURRENT_BACKUP/config/" 2>/dev/null || true
    cp "$PROJECT_DIR/docker-compose.yml" "$CURRENT_BACKUP/config/"
    cp -r "$PROJECT_DIR/nginx" "$CURRENT_BACKUP/config/"
    cp -r "$PROJECT_DIR/orthanc" "$CURRENT_BACKUP/config/"
    cp -r "$PROJECT_DIR/ohif" "$CURRENT_BACKUP/config/"
    cp -r "$PROJECT_DIR/keycloak" "$CURRENT_BACKUP/config/"
    cp -r "$PROJECT_DIR/monitoring" "$CURRENT_BACKUP/config/"

    log_success "Configuration backup completed."
}

# Backup DICOM storage (incremental using rsync)
backup_dicom() {
    if [[ "$INCLUDE_DICOM" != "true" ]]; then
        log_info "Skipping DICOM storage backup (use --include-dicom to include)."
        return
    fi

    log_info "Backing up DICOM storage (this may take a while)..."

    local dicom_source="${DICOM_STORAGE_PATH:-$PROJECT_DIR/data/dicom}"
    local dicom_dest="$BACKUP_DIR/dicom-storage"

    # Create destination if not exists
    mkdir -p "$dicom_dest"

    # Use rsync for incremental backup
    if command -v rsync &> /dev/null; then
        rsync -av --delete \
            --link-dest="$dicom_dest/current" \
            "$dicom_source/" \
            "$dicom_dest/$TIMESTAMP/"

        # Update current link
        rm -f "$dicom_dest/current"
        ln -s "$dicom_dest/$TIMESTAMP" "$dicom_dest/current"

        log_success "DICOM storage backup completed (incremental)."
    else
        # Fallback to tar
        tar -czf "$CURRENT_BACKUP/dicom-storage.tar.gz" \
            -C "$(dirname "$dicom_source")" \
            "$(basename "$dicom_source")"

        log_success "DICOM storage backup completed (full archive)."
    fi
}

# Create backup manifest
create_manifest() {
    log_info "Creating backup manifest..."

    cat > "$CURRENT_BACKUP/manifest.json" << EOF
{
    "backup_name": "$BACKUP_NAME",
    "timestamp": "$(date -Iseconds)",
    "hostname": "$(hostname)",
    "components": {
        "postgres": true,
        "keycloak_realm": $INCLUDE_REALM,
        "config": true,
        "dicom_storage": $INCLUDE_DICOM
    },
    "files": $(find "$CURRENT_BACKUP" -type f | wc -l),
    "size_bytes": $(du -sb "$CURRENT_BACKUP" | cut -f1)
}
EOF

    log_success "Manifest created."
}

# Compress backup
compress_backup() {
    log_info "Compressing backup..."

    cd "$BACKUP_DIR"
    tar -czf "$BACKUP_NAME.tar.gz" "$BACKUP_NAME"
    rm -rf "$BACKUP_NAME"

    local size=$(du -h "$BACKUP_NAME.tar.gz" | cut -f1)
    log_success "Backup compressed: $BACKUP_NAME.tar.gz ($size)"
}

# Rotate old backups
rotate_backups() {
    log_info "Rotating old backups..."

    cd "$BACKUP_DIR"

    # Get list of backups sorted by date
    local backups=($(ls -t dicom-backup-*.tar.gz 2>/dev/null || true))
    local count=${#backups[@]}

    if [[ $count -le $KEEP_DAILY ]]; then
        log_info "No backups to rotate (have $count, keeping $KEEP_DAILY daily)"
        return
    fi

    # Keep daily backups
    local to_delete=("${backups[@]:$KEEP_DAILY}")

    for backup in "${to_delete[@]}"; do
        log_info "  Removing old backup: $backup"
        rm -f "$backup"
    done

    log_success "Backup rotation completed."
}

# Main function
main() {
    echo "=============================================="
    echo "  DICOM Web Viewer Stack - Backup"
    echo "=============================================="
    echo ""
    echo "Backup directory: $CURRENT_BACKUP"
    echo "Include DICOM: $INCLUDE_DICOM"
    echo "Include Realm: $INCLUDE_REALM"
    echo ""

    create_backup_dir
    backup_postgres
    backup_keycloak_realm
    backup_config
    backup_dicom
    create_manifest
    compress_backup
    rotate_backups

    echo ""
    echo "=============================================="
    log_success "Backup completed successfully!"
    echo "=============================================="
    echo ""
    echo "Backup file: $BACKUP_DIR/$BACKUP_NAME.tar.gz"
    echo ""
}

# Run main function
main "$@"
