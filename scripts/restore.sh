#!/bin/bash
# =============================================================================
# DICOM Web Viewer Stack - Restore Script
# =============================================================================
# Restores from a backup created by backup.sh
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

# Log functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Show usage
usage() {
    echo "Usage: $0 <backup-file.tar.gz> [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --postgres-only   Only restore PostgreSQL databases"
    echo "  --config-only     Only restore configuration files"
    echo "  --no-restart      Don't restart services after restore"
    echo "  -y, --yes         Skip confirmation prompts"
    echo "  -h, --help        Show this help message"
    exit 0
}

# Parse arguments
BACKUP_FILE=""
POSTGRES_ONLY=false
CONFIG_ONLY=false
NO_RESTART=false
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --postgres-only)
            POSTGRES_ONLY=true
            shift
            ;;
        --config-only)
            CONFIG_ONLY=true
            shift
            ;;
        --no-restart)
            NO_RESTART=true
            shift
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [[ -z "$BACKUP_FILE" ]]; then
                BACKUP_FILE="$1"
            else
                log_error "Unknown option: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate backup file
if [[ -z "$BACKUP_FILE" ]]; then
    log_error "Backup file is required"
    usage
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
    log_error "Backup file not found: $BACKUP_FILE"
    exit 1
fi

# Confirmation prompt
confirm_restore() {
    if [[ "$SKIP_CONFIRM" == "true" ]]; then
        return
    fi

    echo ""
    log_warn "WARNING: This will restore from backup and may overwrite existing data!"
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        log_info "Restore cancelled."
        exit 0
    fi
}

# Extract backup
extract_backup() {
    log_info "Extracting backup..."

    TEMP_DIR=$(mktemp -d)
    tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR"

    # Find the backup directory (it's the only directory in temp)
    BACKUP_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)

    if [[ -z "$BACKUP_DIR" ]]; then
        log_error "Invalid backup archive"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    log_success "Backup extracted to: $BACKUP_DIR"
}

# Stop services
stop_services() {
    if [[ "$NO_RESTART" == "true" ]]; then
        return
    fi

    log_info "Stopping services..."
    cd "$PROJECT_DIR"
    docker compose down || true
    log_success "Services stopped."
}

# Restore PostgreSQL databases
restore_postgres() {
    if [[ "$CONFIG_ONLY" == "true" ]]; then
        return
    fi

    log_info "Restoring PostgreSQL databases..."

    # Start only postgres
    cd "$PROJECT_DIR"
    docker compose up -d postgres
    sleep 10  # Wait for postgres to be ready

    # Restore Orthanc database
    if [[ -f "$BACKUP_DIR/postgres/orthanc.sql.gz" ]]; then
        log_info "  - Restoring Orthanc database..."

        # Drop and recreate database
        docker compose exec -T postgres psql -U "${POSTGRES_USER:-dicom}" -c \
            "DROP DATABASE IF EXISTS ${POSTGRES_DB:-orthanc}; CREATE DATABASE ${POSTGRES_DB:-orthanc};"

        # Restore
        gunzip -c "$BACKUP_DIR/postgres/orthanc.sql.gz" | \
            docker compose exec -T postgres psql -U "${POSTGRES_USER:-dicom}" -d "${POSTGRES_DB:-orthanc}"

        log_success "  Orthanc database restored."
    fi

    # Restore Keycloak database
    if [[ -f "$BACKUP_DIR/postgres/keycloak.sql.gz" ]]; then
        log_info "  - Restoring Keycloak database..."

        # Drop and recreate database
        docker compose exec -T postgres psql -U "${POSTGRES_USER:-dicom}" -c \
            "DROP DATABASE IF EXISTS keycloak; CREATE DATABASE keycloak;"

        # Restore
        gunzip -c "$BACKUP_DIR/postgres/keycloak.sql.gz" | \
            docker compose exec -T postgres psql -U "${POSTGRES_USER:-dicom}" -d keycloak

        log_success "  Keycloak database restored."
    fi

    log_success "PostgreSQL restore completed."
}

# Restore configuration
restore_config() {
    if [[ "$POSTGRES_ONLY" == "true" ]]; then
        return
    fi

    log_info "Restoring configuration files..."

    # Backup current config
    local config_backup="$PROJECT_DIR/config-backup-$(date +%Y%m%d%H%M%S)"
    mkdir -p "$config_backup"

    # Save current configs
    cp "$PROJECT_DIR/.env" "$config_backup/" 2>/dev/null || true
    cp -r "$PROJECT_DIR/nginx" "$config_backup/" 2>/dev/null || true
    cp -r "$PROJECT_DIR/orthanc" "$config_backup/" 2>/dev/null || true
    cp -r "$PROJECT_DIR/ohif" "$config_backup/" 2>/dev/null || true
    cp -r "$PROJECT_DIR/keycloak" "$config_backup/" 2>/dev/null || true
    cp -r "$PROJECT_DIR/monitoring" "$config_backup/" 2>/dev/null || true

    log_info "  Current config backed up to: $config_backup"

    # Restore from backup
    if [[ -d "$BACKUP_DIR/config" ]]; then
        cp "$BACKUP_DIR/config/.env" "$PROJECT_DIR/" 2>/dev/null || true
        cp -r "$BACKUP_DIR/config/nginx" "$PROJECT_DIR/" 2>/dev/null || true
        cp -r "$BACKUP_DIR/config/orthanc" "$PROJECT_DIR/" 2>/dev/null || true
        cp -r "$BACKUP_DIR/config/ohif" "$PROJECT_DIR/" 2>/dev/null || true
        cp -r "$BACKUP_DIR/config/keycloak" "$PROJECT_DIR/" 2>/dev/null || true
        cp -r "$BACKUP_DIR/config/monitoring" "$PROJECT_DIR/" 2>/dev/null || true
    fi

    log_success "Configuration files restored."
}

# Start services
start_services() {
    if [[ "$NO_RESTART" == "true" ]]; then
        return
    fi

    log_info "Starting services..."
    cd "$PROJECT_DIR"
    docker compose up -d
    log_success "Services started."
}

# Cleanup
cleanup() {
    log_info "Cleaning up..."
    rm -rf "$TEMP_DIR"
    log_success "Cleanup completed."
}

# Main function
main() {
    echo "=============================================="
    echo "  DICOM Web Viewer Stack - Restore"
    echo "=============================================="
    echo ""
    echo "Backup file: $BACKUP_FILE"
    echo ""

    confirm_restore
    extract_backup
    stop_services
    restore_postgres
    restore_config
    start_services
    cleanup

    echo ""
    echo "=============================================="
    log_success "Restore completed successfully!"
    echo "=============================================="
    echo ""
    echo "Please verify that all services are running correctly:"
    echo "  docker compose ps"
    echo ""
}

# Run main function
main "$@"
