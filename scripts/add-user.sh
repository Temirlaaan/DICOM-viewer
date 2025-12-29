#!/bin/bash
# =============================================================================
# DICOM Web Viewer Stack - Add User Script
# =============================================================================
# Creates a new user in Keycloak and assigns them to a clinic
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

# Log functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Show usage
usage() {
    echo "Usage: $0 <username> <email> <clinic_id> [OPTIONS]"
    echo ""
    echo "Arguments:"
    echo "  username    Username for the new user"
    echo "  email       Email address"
    echo "  clinic_id   Clinic group to assign (e.g., denscan-central)"
    echo ""
    echo "Options:"
    echo "  --role ROLE         Role to assign (admin, physician, technician)"
    echo "                      Default: physician"
    echo "  --first-name NAME   First name"
    echo "  --last-name NAME    Last name"
    echo "  --password PASS     Initial password (will be prompted if not provided)"
    echo "  --send-email        Send password reset email to user"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 dr.smith smith@clinic.com denscan-central --role physician"
    exit 0
}

# Parse arguments
USERNAME=""
EMAIL=""
CLINIC_ID=""
ROLE="physician"
FIRST_NAME=""
LAST_NAME=""
PASSWORD=""
SEND_EMAIL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --role)
            ROLE="$2"
            shift 2
            ;;
        --first-name)
            FIRST_NAME="$2"
            shift 2
            ;;
        --last-name)
            LAST_NAME="$2"
            shift 2
            ;;
        --password)
            PASSWORD="$2"
            shift 2
            ;;
        --send-email)
            SEND_EMAIL=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [[ -z "$USERNAME" ]]; then
                USERNAME="$1"
            elif [[ -z "$EMAIL" ]]; then
                EMAIL="$1"
            elif [[ -z "$CLINIC_ID" ]]; then
                CLINIC_ID="$1"
            else
                log_error "Unknown option: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate arguments
if [[ -z "$USERNAME" || -z "$EMAIL" || -z "$CLINIC_ID" ]]; then
    log_error "Missing required arguments"
    usage
fi

# Validate role
if [[ ! "$ROLE" =~ ^(admin|physician|technician)$ ]]; then
    log_error "Invalid role: $ROLE (must be admin, physician, or technician)"
    exit 1
fi

# Get admin password if not set
if [[ -z "$KEYCLOAK_ADMIN_PASSWORD" ]]; then
    read -sp "Enter Keycloak admin password: " KEYCLOAK_ADMIN_PASSWORD
    echo ""
fi

# Generate password if not provided
if [[ -z "$PASSWORD" && "$SEND_EMAIL" != "true" ]]; then
    PASSWORD=$(openssl rand -base64 12)
    log_info "Generated password: $PASSWORD"
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

# Get group ID by path
get_group_id() {
    local group_path="$1"
    local token="$2"

    local response
    response=$(curl -s -X GET \
        "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/groups" \
        -H "Authorization: Bearer $token")

    # Find clinics group, then find the specific clinic
    echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
def find_group(groups, path):
    for g in groups:
        if g.get('path') == path:
            return g.get('id')
        if 'subGroups' in g:
            result = find_group(g['subGroups'], path)
            if result:
                return result
    return None
print(find_group(data, '/clinics/$CLINIC_ID') or '')
" 2>/dev/null || echo ""
}

# Get role ID
get_role_id() {
    local role_name="$1"
    local token="$2"

    local response
    response=$(curl -s -X GET \
        "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/roles" \
        -H "Authorization: Bearer $token")

    echo "$response" | grep -o "\"id\":\"[^\"]*\",\"name\":\"$role_name\"" | head -1 | cut -d'"' -f4
}

# Main function
main() {
    log_info "Creating user: $USERNAME ($EMAIL)"
    log_info "Clinic: $CLINIC_ID, Role: $ROLE"

    # Get token
    log_info "Authenticating with Keycloak..."
    TOKEN=$(get_token)

    if [[ -z "$TOKEN" ]]; then
        log_error "Failed to authenticate with Keycloak"
        exit 1
    fi

    # Get group ID
    log_info "Looking up clinic group..."
    GROUP_ID=$(get_group_id "/clinics/$CLINIC_ID" "$TOKEN")

    if [[ -z "$GROUP_ID" ]]; then
        log_error "Clinic group not found: $CLINIC_ID"
        log_info "Available clinics can be viewed in Keycloak admin console"
        exit 1
    fi

    # Create user
    log_info "Creating user..."

    local user_data="{
        \"username\": \"$USERNAME\",
        \"email\": \"$EMAIL\",
        \"emailVerified\": true,
        \"enabled\": true,
        \"firstName\": \"${FIRST_NAME:-$USERNAME}\",
        \"lastName\": \"${LAST_NAME:-}\",
        \"groups\": [\"/clinics/$CLINIC_ID\"],
        \"attributes\": {
            \"clinic_ids\": [\"$CLINIC_ID\"]
        }
    }"

    local create_response
    create_response=$(curl -s -w "\n%{http_code}" -X POST \
        "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/users" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$user_data")

    local http_code
    http_code=$(echo "$create_response" | tail -1)

    if [[ "$http_code" != "201" ]]; then
        log_error "Failed to create user (HTTP $http_code)"
        echo "$create_response" | head -n -1
        exit 1
    fi

    log_success "User created."

    # Get user ID
    local user_response
    user_response=$(curl -s -X GET \
        "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/users?username=$USERNAME" \
        -H "Authorization: Bearer $TOKEN")

    USER_ID=$(echo "$user_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -z "$USER_ID" ]]; then
        log_error "Failed to get user ID"
        exit 1
    fi

    # Set password or send email
    if [[ -n "$PASSWORD" ]]; then
        log_info "Setting password..."

        curl -s -X PUT \
            "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/users/$USER_ID/reset-password" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d "{
                \"type\": \"password\",
                \"value\": \"$PASSWORD\",
                \"temporary\": true
            }"

        log_success "Password set (user will be prompted to change on first login)."
    fi

    if [[ "$SEND_EMAIL" == "true" ]]; then
        log_info "Sending password reset email..."

        curl -s -X PUT \
            "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/users/$USER_ID/execute-actions-email" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d '["UPDATE_PASSWORD"]'

        log_success "Password reset email sent."
    fi

    # Assign role
    log_info "Assigning role: $ROLE..."

    ROLE_ID=$(get_role_id "$ROLE" "$TOKEN")

    if [[ -n "$ROLE_ID" ]]; then
        curl -s -X POST \
            "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/users/$USER_ID/role-mappings/realm" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d "[{\"id\": \"$ROLE_ID\", \"name\": \"$ROLE\"}]"

        log_success "Role assigned."
    else
        log_warn "Could not find role: $ROLE"
    fi

    # Add to group (explicit, in case it wasn't done during creation)
    log_info "Adding to clinic group..."

    curl -s -X PUT \
        "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/users/$USER_ID/groups/$GROUP_ID" \
        -H "Authorization: Bearer $TOKEN"

    log_success "Added to clinic group."

    echo ""
    echo "=============================================="
    log_success "User created successfully!"
    echo "=============================================="
    echo ""
    echo "Username: $USERNAME"
    echo "Email: $EMAIL"
    echo "Clinic: $CLINIC_ID"
    echo "Role: $ROLE"
    if [[ -n "$PASSWORD" && "$SEND_EMAIL" != "true" ]]; then
        echo "Password: $PASSWORD (temporary, must change on first login)"
    fi
    echo ""
}

# Run main function
main "$@"
