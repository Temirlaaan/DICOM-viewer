#!/bin/bash
# =============================================================================
# DICOM Web Viewer Stack - Initial Setup Script
# =============================================================================
# This script performs the initial setup for the DICOM Web Viewer stack.
# Run this once before starting the stack for the first time.
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Log functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_warn "Running as root is not recommended. Consider using a regular user with docker group membership."
    fi
}

# Check dependencies
check_dependencies() {
    log_info "Checking dependencies..."

    local deps=("docker" "docker-compose" "openssl" "curl")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_info "Please install the missing dependencies and try again."
        exit 1
    fi

    # Check Docker is running
    if ! docker info &> /dev/null; then
        log_error "Docker is not running. Please start Docker and try again."
        exit 1
    fi

    log_success "All dependencies are installed."
}

# Create .env file from example
create_env_file() {
    log_info "Creating environment configuration..."

    if [[ -f "$PROJECT_DIR/.env" ]]; then
        log_warn ".env file already exists. Skipping..."
        return
    fi

    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"

    # Generate random passwords
    local postgres_pw=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    local keycloak_pw=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    local orthanc_pw=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
    local grafana_pw=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)

    # Replace placeholders
    sed -i "s/CHANGE_ME_STRONG_PASSWORD_32_CHARS/$postgres_pw/g" "$PROJECT_DIR/.env"
    sed -i "s/CHANGE_ME_ADMIN_PASSWORD_32_CHARS/$keycloak_pw/g" "$PROJECT_DIR/.env"
    sed -i "s/CHANGE_ME_ORTHANC_PASSWORD/$orthanc_pw/g" "$PROJECT_DIR/.env"
    sed -i "s/CHANGE_ME_GRAFANA_PASSWORD/$grafana_pw/g" "$PROJECT_DIR/.env"

    log_success ".env file created with random passwords."
    log_warn "Please review and update the .env file with your domain settings."
}

# Create data directories
create_directories() {
    log_info "Creating data directories..."

    local dirs=(
        "$PROJECT_DIR/data/dicom"
        "$PROJECT_DIR/data/inbox"
        "$PROJECT_DIR/data/processed"
        "$PROJECT_DIR/data/failed"
        "$PROJECT_DIR/backup"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        log_info "Created: $dir"
    done

    # Create sample clinic directories
    mkdir -p "$PROJECT_DIR/data/inbox/denscan-central"
    mkdir -p "$PROJECT_DIR/data/inbox/denscan-almaty"
    mkdir -p "$PROJECT_DIR/data/inbox/partner-clinic"

    log_success "Data directories created."
}

# Generate self-signed SSL certificates for development
generate_dev_certs() {
    log_info "Generating self-signed SSL certificates for development..."

    local ssl_dir="$PROJECT_DIR/nginx/ssl"

    if [[ -f "$ssl_dir/fullchain.pem" ]]; then
        log_warn "SSL certificates already exist. Skipping..."
        return
    fi

    # Generate self-signed certificate
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$ssl_dir/privkey.pem" \
        -out "$ssl_dir/fullchain.pem" \
        -subj "/C=KZ/ST=Almaty/L=Almaty/O=DenScan/OU=IT/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,DNS:imaging.denscan.kz,IP:127.0.0.1"

    log_success "Self-signed SSL certificates generated."
    log_warn "For production, use Let's Encrypt certificates."
}

# Create PostgreSQL initialization script
create_db_init_script() {
    log_info "Creating database initialization script..."

    cat > "$PROJECT_DIR/scripts/init-multiple-databases.sh" << 'EOF'
#!/bin/bash
set -e

# Create additional databases
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE keycloak;
    GRANT ALL PRIVILEGES ON DATABASE keycloak TO $POSTGRES_USER;
    GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB TO $POSTGRES_USER;
EOSQL

echo "Additional databases created successfully"
EOF

    chmod +x "$PROJECT_DIR/scripts/init-multiple-databases.sh"
    log_success "Database initialization script created."
}

# Pull Docker images
pull_images() {
    log_info "Pulling Docker images (this may take a while)..."

    cd "$PROJECT_DIR"
    docker-compose pull

    log_success "Docker images pulled."
}

# Build custom images
build_images() {
    log_info "Building custom Docker images..."

    cd "$PROJECT_DIR"
    docker-compose build

    log_success "Custom Docker images built."
}

# Create Keycloak client secrets
update_keycloak_secrets() {
    log_info "Updating Keycloak client secrets..."

    local realm_file="$PROJECT_DIR/keycloak/realm-export.json"
    local orthanc_secret=$(openssl rand -hex 32)
    local grafana_secret=$(openssl rand -hex 32)
    local admin_secret=$(openssl rand -hex 32)

    # Update secrets in realm export
    sed -i "s/CHANGE_ME_ORTHANC_CLIENT_SECRET/$orthanc_secret/g" "$realm_file"
    sed -i "s/CHANGE_ME_GRAFANA_CLIENT_SECRET/$grafana_secret/g" "$realm_file"
    sed -i "s/CHANGE_ME_ADMIN_CLI_SECRET/$admin_secret/g" "$realm_file"

    # Save secrets to .env
    echo "" >> "$PROJECT_DIR/.env"
    echo "# Keycloak Client Secrets (auto-generated)" >> "$PROJECT_DIR/.env"
    echo "ORTHANC_CLIENT_SECRET=$orthanc_secret" >> "$PROJECT_DIR/.env"
    echo "GRAFANA_OAUTH_SECRET=$grafana_secret" >> "$PROJECT_DIR/.env"
    echo "ADMIN_CLI_SECRET=$admin_secret" >> "$PROJECT_DIR/.env"

    log_success "Keycloak client secrets updated."
}

# Main setup function
main() {
    echo "=============================================="
    echo "  DICOM Web Viewer Stack - Setup"
    echo "=============================================="
    echo ""

    check_root
    check_dependencies
    create_env_file
    create_directories
    generate_dev_certs
    create_db_init_script
    update_keycloak_secrets
    pull_images
    build_images

    echo ""
    echo "=============================================="
    log_success "Setup completed successfully!"
    echo "=============================================="
    echo ""
    echo "Next steps:"
    echo "  1. Review and update .env file with your domain settings"
    echo "  2. For production: Configure SSL certificates"
    echo "  3. Start the stack: make up"
    echo "  4. Access the viewer: https://localhost (or your domain)"
    echo "  5. Login with: admin / (check Keycloak for initial password)"
    echo ""
}

# Run main function
main "$@"
