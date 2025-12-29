# Keycloak Configuration

This directory contains the Keycloak Identity Provider configuration for the DICOM Web Viewer stack.

## Realm: `dicom`

The pre-configured realm includes:

### Clients

| Client ID | Type | Purpose |
|-----------|------|---------|
| `ohif-viewer` | Public (PKCE) | OHIF SPA authentication |
| `orthanc-api` | Confidential | Backend token validation |
| `grafana` | Confidential | Grafana OAuth integration |
| `admin-cli` | Confidential | CLI scripts for user management |

### Roles

| Role | Description |
|------|-------------|
| `admin` | Full administrative access |
| `physician` | View studies from assigned clinics |
| `technician` | Upload studies only |

### Groups

Clinics are organized as groups under `/clinics/`:

```
/clinics
├── denscan-central    (clinic_id: denscan-central)
├── denscan-almaty     (clinic_id: denscan-almaty)
└── partner-clinic     (clinic_id: partner-clinic)
```

### Token Claims

Custom protocol mappers add these claims to tokens:

- `clinic_ids`: Array of clinic IDs from user's group memberships
- `groups`: Array of group paths
- `roles`: Array of realm roles

## First-Time Setup

1. **Change default secrets** in `realm-export.json`:
   - `orthanc-api` client secret
   - `grafana` client secret
   - `admin-cli` client secret

2. **Update admin password** after first login:
   - Default: `admin` / `CHANGE_ME_ON_FIRST_LOGIN`
   - Password change is required on first login

3. **Configure SMTP** for password reset emails:
   - Go to Realm Settings → Email
   - Configure SMTP server details

4. **Enable TOTP** (optional but recommended):
   - Go to Authentication → Policies → OTP Policy
   - Configure OTP requirements

## Adding a New Clinic

```bash
# Using the management script
./scripts/add-clinic.sh clinic-id "Clinic Display Name"

# Or manually in Keycloak Admin Console:
# 1. Go to Groups → clinics → Create group
# 2. Set group name (e.g., "new-clinic")
# 3. Add attribute: clinic_id = new-clinic
# 4. Create inbox folder: mkdir -p /data/inbox/new-clinic
```

## Adding a New User

```bash
# Using the management script
./scripts/add-user.sh username email@domain.com clinic-id

# Or manually in Keycloak Admin Console:
# 1. Go to Users → Add user
# 2. Fill in username, email, first/last name
# 3. Set email verified = ON
# 4. Go to Credentials → Set password
# 5. Go to Groups → Join group → select clinic
# 6. Go to Role mappings → Assign role (physician/technician)
# 7. Add attribute: clinic_ids = [list of clinic IDs]
```

## Security Settings

The realm is configured with:

| Setting | Value |
|---------|-------|
| Password Policy | Min 12 chars, upper, lower, digit, not username |
| Brute Force Protection | ON (5 failures → lockout) |
| Session Idle Timeout | 8 hours |
| Session Max Lifespan | 10 hours |
| Access Token Lifespan | 5 minutes |
| Refresh Token | 24 hours (offline) |

## Troubleshooting

### User can't log in

1. Check user is enabled
2. Verify email is verified
3. Check for account lockout (brute force protection)
4. Verify password meets policy

### Token doesn't contain clinic_ids

1. Ensure user is member of a clinic group
2. Verify group has `clinic_id` attribute set
3. Check user has `clinic_ids` attribute populated
4. Verify protocol mapper is configured for the client

### CORS errors

1. Check Web Origins in client settings
2. Verify redirect URIs include your domain
3. Check nginx CORS headers

## Backup

Keycloak data is stored in PostgreSQL. The realm can be exported:

```bash
# Export realm (excludes users by default)
docker compose exec keycloak /opt/keycloak/bin/kc.sh export \
  --dir /opt/keycloak/data/export \
  --realm dicom

# Export with users
docker compose exec keycloak /opt/keycloak/bin/kc.sh export \
  --dir /opt/keycloak/data/export \
  --realm dicom \
  --users realm_file
```

## Custom Themes

Place custom theme files in the `themes/` directory:

```
themes/
└── custom/
    ├── login/
    │   ├── theme.properties
    │   ├── login.ftl
    │   └── resources/
    │       ├── css/
    │       └── img/
    └── account/
        └── ...
```

Then set in realm settings:
- Login Theme: custom
- Account Theme: custom
