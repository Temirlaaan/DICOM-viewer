#!/bin/bash
# =============================================================================
# DICOM Web Viewer Stack - SSL Certificate Generator
# =============================================================================
# Generates SSL certificates for the DICOM Web Viewer stack.
# Supports both self-signed (development) and Let's Encrypt (production).
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
SSL_DIR="$PROJECT_DIR/nginx/ssl"
DOMAIN="${DOMAIN:-localhost}"
EMAIL="${LETSENCRYPT_EMAIL:-admin@$DOMAIN}"

# Log functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Show usage
usage() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  self-signed    Generate self-signed certificate (default)"
    echo "  letsencrypt    Generate Let's Encrypt certificate"
    echo "  renew          Renew Let's Encrypt certificate"
    echo ""
    echo "Options:"
    echo "  --domain DOMAIN   Domain name (default: from .env or localhost)"
    echo "  --email EMAIL     Email for Let's Encrypt notifications"
    echo "  --staging         Use Let's Encrypt staging server (for testing)"
    echo "  --force           Force regeneration even if certificates exist"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 self-signed"
    echo "  $0 letsencrypt --domain imaging.denscan.kz --email admin@denscan.kz"
    echo "  $0 renew"
    exit 0
}

# Parse arguments
COMMAND="self-signed"
USE_STAGING=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        self-signed|letsencrypt|renew)
            COMMAND="$1"
            shift
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --email)
            EMAIL="$2"
            shift 2
            ;;
        --staging)
            USE_STAGING=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if certificates exist
check_existing_certs() {
    if [[ -f "$SSL_DIR/fullchain.pem" && -f "$SSL_DIR/privkey.pem" ]]; then
        if [[ "$FORCE" != "true" ]]; then
            log_warn "Certificates already exist. Use --force to regenerate."
            exit 0
        fi
        log_info "Forcing certificate regeneration..."
    fi
}

# Generate self-signed certificate
generate_self_signed() {
    log_info "Generating self-signed certificate for: $DOMAIN"

    mkdir -p "$SSL_DIR"

    # Generate private key and certificate
    openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
        -keyout "$SSL_DIR/privkey.pem" \
        -out "$SSL_DIR/fullchain.pem" \
        -subj "/C=KZ/ST=Almaty/L=Almaty/O=DenScan/OU=IT/CN=$DOMAIN" \
        -addext "subjectAltName=DNS:$DOMAIN,DNS:localhost,IP:127.0.0.1"

    # Set permissions
    chmod 644 "$SSL_DIR/fullchain.pem"
    chmod 600 "$SSL_DIR/privkey.pem"

    log_success "Self-signed certificate generated:"
    log_info "  Certificate: $SSL_DIR/fullchain.pem"
    log_info "  Private Key: $SSL_DIR/privkey.pem"
    log_warn "This certificate will show a security warning in browsers."
    log_info "For production, use 'letsencrypt' command instead."
}

# Generate Let's Encrypt certificate
generate_letsencrypt() {
    log_info "Generating Let's Encrypt certificate for: $DOMAIN"

    # Check if certbot is installed
    if ! command -v certbot &> /dev/null; then
        log_error "certbot is not installed. Please install it first:"
        log_info "  Ubuntu/Debian: sudo apt install certbot"
        log_info "  CentOS/RHEL: sudo yum install certbot"
        exit 1
    fi

    # Prepare certbot arguments
    local certbot_args=(
        "certonly"
        "--standalone"
        "-d" "$DOMAIN"
        "--email" "$EMAIL"
        "--agree-tos"
        "--non-interactive"
    )

    if [[ "$USE_STAGING" == "true" ]]; then
        certbot_args+=("--staging")
        log_warn "Using Let's Encrypt staging server (certificates won't be trusted)"
    fi

    # Stop nginx if running (to free port 80)
    log_info "Stopping nginx temporarily..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" stop nginx 2>/dev/null || true

    # Run certbot
    log_info "Running certbot..."
    sudo certbot "${certbot_args[@]}"

    # Copy certificates
    log_info "Copying certificates..."
    sudo cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SSL_DIR/fullchain.pem"
    sudo cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SSL_DIR/privkey.pem"
    sudo chown "$(whoami):$(whoami)" "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem"
    chmod 644 "$SSL_DIR/fullchain.pem"
    chmod 600 "$SSL_DIR/privkey.pem"

    # Start nginx
    log_info "Starting nginx..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" start nginx 2>/dev/null || true

    log_success "Let's Encrypt certificate generated:"
    log_info "  Certificate: $SSL_DIR/fullchain.pem"
    log_info "  Private Key: $SSL_DIR/privkey.pem"
    log_info "  Expires: $(openssl x509 -in "$SSL_DIR/fullchain.pem" -noout -enddate | cut -d= -f2)"
}

# Renew Let's Encrypt certificate
renew_letsencrypt() {
    log_info "Renewing Let's Encrypt certificates..."

    if ! command -v certbot &> /dev/null; then
        log_error "certbot is not installed"
        exit 1
    fi

    # Stop nginx
    log_info "Stopping nginx temporarily..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" stop nginx 2>/dev/null || true

    # Renew
    sudo certbot renew

    # Copy renewed certificates
    if [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
        sudo cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SSL_DIR/fullchain.pem"
        sudo cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SSL_DIR/privkey.pem"
        sudo chown "$(whoami):$(whoami)" "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem"
    fi

    # Start nginx
    log_info "Starting nginx..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" start nginx 2>/dev/null || true

    log_success "Certificate renewal completed."
    log_info "  Expires: $(openssl x509 -in "$SSL_DIR/fullchain.pem" -noout -enddate | cut -d= -f2)"
}

# Show certificate info
show_cert_info() {
    if [[ -f "$SSL_DIR/fullchain.pem" ]]; then
        echo ""
        log_info "Current certificate info:"
        openssl x509 -in "$SSL_DIR/fullchain.pem" -noout \
            -subject -issuer -dates 2>/dev/null || true
    fi
}

# Setup auto-renewal cron job
setup_auto_renewal() {
    log_info "Setting up auto-renewal cron job..."

    local cron_cmd="0 3 * * * $SCRIPT_DIR/generate-certs.sh renew >> /var/log/letsencrypt-renew.log 2>&1"

    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -q "generate-certs.sh renew"; then
        log_info "Auto-renewal cron job already exists"
    else
        (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
        log_success "Auto-renewal cron job added (runs daily at 3 AM)"
    fi
}

# Main function
main() {
    echo "=============================================="
    echo "  SSL Certificate Generator"
    echo "=============================================="
    echo ""
    echo "Command: $COMMAND"
    echo "Domain: $DOMAIN"
    echo ""

    mkdir -p "$SSL_DIR"

    case "$COMMAND" in
        self-signed)
            check_existing_certs
            generate_self_signed
            ;;
        letsencrypt)
            check_existing_certs
            generate_letsencrypt
            setup_auto_renewal
            ;;
        renew)
            renew_letsencrypt
            ;;
    esac

    show_cert_info

    echo ""
    echo "=============================================="
    log_success "Done!"
    echo "=============================================="
}

# Run main function
main "$@"
