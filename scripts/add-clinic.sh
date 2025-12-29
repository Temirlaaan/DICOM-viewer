#!/bin/bash
# =============================================================================
# DICOM Web Viewer Stack - Add Clinic Script
# =============================================================================
# Creates a new clinic group in Keycloak and corresponding inbox folders
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
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-dicom}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
INBOX_PATH="${INBOX_PATH:-$PROJECT_DIR/data/inbox}"
PROCESSED_PATH="${PROCESSED_PATH:-$PROJECT_DIR/data/processed}"
FAILED_PATH="${FAILED_PATH:-$PROJECT_DIR/data/failed}"

# Log functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Show usage
usage() {
    echo "Usage: $0 <clinic_id> <clinic_name> [OPTIONS]"
    echo ""
    echo "Arguments:"
    echo "  clinic_id     Unique identifier for the clinic (e.g., clinic-almaty)"
    echo "                Must be lowercase, alphanumeric with hyphens"
    echo "  clinic_name   Display name for the clinic (e.g., \"Almaty Dental Clinic\")"
    echo ""
    echo "Options:"
    echo "  --address ADDRESS   Clinic address"
    echo "  --phone PHONE       Clinic phone number"
    echo "  --no-folders        Don't create inbox/processed/failed folders"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 clinic-almaty \"Almaty Dental Clinic\" --phone \"+7 727 123 4567\""
    exit 0
}

# Parse arguments
CLINIC_ID=""
CLINIC_NAME=""
CLINIC_ADDRESS=""
CLINIC_PHONE=""
CREATE_FOLDERS=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --address)
            CLINIC_ADDRESS="$2"
            shift 2
            ;;
        --phone)
            CLINIC_PHONE="$2"
            shift 2
            ;;
        --no-folders)
            CREATE_FOLDERS=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [[ -z "$CLINIC_ID" ]]; then
                CLINIC_ID="$1"
            elif [[ -z "$CLINIC_NAME" ]]; then
                CLINIC_NAME="$1"
            else
                log_error "Unknown option: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate arguments
if [[ -z "$CLINIC_ID" || -z "$CLINIC_NAME" ]]; then
    log_error "Missing required arguments"
    usage
fi

# Validate clinic_id format
if [[ ! "$CLINIC_ID" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
    log_error "Invalid clinic_id format: $CLINIC_ID"
    log_info "Must be lowercase, start and end with alphanumeric, can contain hyphens"
    exit 1
fi

# Get admin password if not set
if [[ -z "$KEYCLOAK_ADMIN_PASSWORD" ]]; then
    read -sp "Enter Keycloak admin password: " KEYCLOAK_ADMIN_PASSWORD
    echo ""
fi

# Get access token
get_token() {
    local response
    response=$(curl -s -X POST \
        "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=$KEYCLOAK_ADMIN" \
        -d "password=$KEYCLOAK_ADMIN_PASSWORD" \
        -d "grant_type=password" \
        -d "client_id=admin-cli")

    echo "$response" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

# Get parent group ID (clinics group)
get_clinics_group_id() {
    local token="$1"

    local response
    response=$(curl -s -X GET \
        "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/groups" \
        -H "Authorization: Bearer $token")

    echo "$response" | grep -o '"id":"[^"]*","name":"clinics"' | head -1 | cut -d'"' -f4
}

# Create clinic group
create_clinic_group() {
    local token="$1"
    local parent_id="$2"

    # Build attributes
    local attributes="{\"clinic_id\": [\"$CLINIC_ID\"], \"clinic_name\": [\"$CLINIC_NAME\"]"

    if [[ -n "$CLINIC_ADDRESS" ]]; then
        attributes="$attributes, \"address\": [\"$CLINIC_ADDRESS\"]"
    fi

    if [[ -n "$CLINIC_PHONE" ]]; then
        attributes="$attributes, \"phone\": [\"$CLINIC_PHONE\"]"
    fi

    attributes="$attributes}"

    local group_data="{
        \"name\": \"$CLINIC_ID\",
        \"attributes\": $attributes
    }"

    local create_response
    create_response=$(curl -s -w "\n%{http_code}" -X POST \
        "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/groups/$parent_id/children" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$group_data")

    local http_code
    http_code=$(echo "$create_response" | tail -1)

    if [[ "$http_code" == "201" || "$http_code" == "409" ]]; then
        if [[ "$http_code" == "409" ]]; then
            log_warn "Clinic group already exists in Keycloak"
        else
            log_success "Clinic group created in Keycloak"
        fi
        return 0
    else
        log_error "Failed to create clinic group (HTTP $http_code)"
        echo "$create_response" | head -n -1
        return 1
    fi
}

# Create folders
create_folders() {
    if [[ "$CREATE_FOLDERS" != "true" ]]; then
        log_info "Skipping folder creation (--no-folders)"
        return
    fi

    log_info "Creating inbox/processed/failed folders..."

    # Create directories
    mkdir -p "$INBOX_PATH/$CLINIC_ID"
    mkdir -p "$PROCESSED_PATH/$CLINIC_ID"
    mkdir -p "$FAILED_PATH/$CLINIC_ID"

    # Set permissions (if running as root or with sudo)
    if [[ -w "$INBOX_PATH/$CLINIC_ID" ]]; then
        chmod 775 "$INBOX_PATH/$CLINIC_ID"
        chmod 775 "$PROCESSED_PATH/$CLINIC_ID"
        chmod 775 "$FAILED_PATH/$CLINIC_ID"
    fi

    log_success "Folders created:"
    log_info "  Inbox: $INBOX_PATH/$CLINIC_ID"
    log_info "  Processed: $PROCESSED_PATH/$CLINIC_ID"
    log_info "  Failed: $FAILED_PATH/$CLINIC_ID"
}

# Main function
main() {
    echo "=============================================="
    echo "  Creating New Clinic"
    echo "=============================================="
    echo ""
    echo "Clinic ID: $CLINIC_ID"
    echo "Clinic Name: $CLINIC_NAME"
    if [[ -n "$CLINIC_ADDRESS" ]]; then
        echo "Address: $CLINIC_ADDRESS"
    fi
    if [[ -n "$CLINIC_PHONE" ]]; then
        echo "Phone: $CLINIC_PHONE"
    fi
    echo ""

    # Get token
    log_info "Authenticating with Keycloak..."
    TOKEN=$(get_token)

    if [[ -z "$TOKEN" ]]; then
        log_error "Failed to authenticate with Keycloak"
        exit 1
    fi

    # Get clinics parent group ID
    log_info "Looking up clinics parent group..."
    PARENT_ID=$(get_clinics_group_id "$TOKEN")

    if [[ -z "$PARENT_ID" ]]; then
        log_error "Could not find 'clinics' group in Keycloak"
        log_info "Please ensure the realm is properly configured"
        exit 1
    fi

    # Create clinic group
    log_info "Creating clinic group in Keycloak..."
    create_clinic_group "$TOKEN" "$PARENT_ID"

    # Create folders
    create_folders

    echo ""
    echo "=============================================="
    log_success "Clinic created successfully!"
    echo "=============================================="
    echo ""
    echo "Next steps:"
    echo "  1. Add users to this clinic: ./scripts/add-user.sh <user> <email> $CLINIC_ID"
    echo "  2. Place DICOM files in: $INBOX_PATH/$CLINIC_ID/"
    echo "  3. Files will be automatically imported with InstitutionName = $CLINIC_ID"
    echo ""
}

# Run main function
main "$@"
