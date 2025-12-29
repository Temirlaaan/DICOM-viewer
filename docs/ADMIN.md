# Administrator Guide

Complete guide for deploying and administering the DICOM Web Viewer Stack.

## Table of Contents

1. [Initial Setup](#initial-setup)
2. [DNS and SSL Configuration](#dns-and-ssl-configuration)
3. [First Admin User](#first-admin-user)
4. [Managing Clinics](#managing-clinics)
5. [Managing Users](#managing-users)
6. [Backup Configuration](#backup-configuration)
7. [Monitoring and Alerts](#monitoring-and-alerts)
8. [Updating Components](#updating-components)
9. [Disaster Recovery](#disaster-recovery)

---

## Initial Setup

### System Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 4 cores | 8+ cores |
| RAM | 8 GB | 16+ GB |
| Storage | 100 GB | 500+ GB SSD |
| OS | Ubuntu 22.04 | Ubuntu 22.04 LTS |

### Step 1: Install Dependencies

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Install Docker Compose
sudo apt install docker-compose-plugin

# Install other tools
sudo apt install -y git curl openssl jq

# Logout and login to apply docker group
```

### Step 2: Clone and Configure

```bash
# Clone repository
git clone <repository-url> /opt/dicom-viewer
cd /opt/dicom-viewer

# Run setup script
./scripts/setup.sh

# Edit configuration
nano .env
```

### Step 3: Configure Environment

Update `.env` with your settings:

```bash
# Domain
DOMAIN=imaging.your-domain.com
EXTERNAL_IP=your.server.ip

# Email for SSL certificates
LETSENCRYPT_EMAIL=admin@your-domain.com

# Timezone
TZ=Asia/Almaty
```

### Step 4: Start Services

```bash
# Start the stack
make up

# Check status
make status

# View logs
make logs
```

---

## DNS and SSL Configuration

### DNS Setup

Create an A record pointing to your server:

```
imaging.your-domain.com  →  your.server.ip
```

Wait for DNS propagation (can take up to 48 hours).

### Production SSL with Let's Encrypt

```bash
# Generate certificate
./scripts/generate-certs.sh letsencrypt \
    --domain imaging.your-domain.com \
    --email admin@your-domain.com

# Restart nginx to apply
docker compose restart nginx
```

### Automatic Renewal

The setup script adds a cron job for automatic renewal. Verify:

```bash
crontab -l | grep generate-certs
```

### Manual Renewal

```bash
./scripts/generate-certs.sh renew
```

---

## First Admin User

### Access Keycloak Admin Console

1. Open https://imaging.your-domain.com/auth/admin
2. Login with credentials from `.env`:
   - Username: `admin`
   - Password: `KEYCLOAK_ADMIN_PASSWORD` from `.env`

### Change Admin Password

1. Go to Users → admin → Credentials
2. Set new password
3. Update `.env` file

### Create First Physician

```bash
./scripts/add-user.sh dr.smith smith@clinic.com denscan-central \
    --role physician \
    --first-name "John" \
    --last-name "Smith"
```

---

## Managing Clinics

### Add New Clinic

```bash
./scripts/add-clinic.sh new-clinic "New Clinic Name" \
    --address "123 Main St" \
    --phone "+7 123 456 7890"
```

This creates:
- Keycloak group: `/clinics/new-clinic`
- Inbox folder: `/data/inbox/new-clinic/`
- Processed folder: `/data/processed/new-clinic/`
- Failed folder: `/data/failed/new-clinic/`

### List Clinics

Via Keycloak Admin:
1. Go to Groups → clinics
2. View subgroups

### Remove Clinic

1. Move all users to another clinic
2. Delete group in Keycloak Admin
3. Archive data folders

---

## Managing Users

### Add User

```bash
# With generated password
./scripts/add-user.sh username email@domain.com clinic-id

# With email notification
./scripts/add-user.sh username email@domain.com clinic-id --send-email

# With custom password
./scripts/add-user.sh username email@domain.com clinic-id --password "TempPass123!"
```

### User Roles

| Role | Permissions |
|------|-------------|
| `admin` | Full access, user management |
| `physician` | View studies from assigned clinics |
| `technician` | Upload only |

### Assign Multiple Clinics

Via Keycloak Admin:
1. Go to Users → select user → Groups
2. Click "Join Group"
3. Select additional clinic groups

### Disable User

```bash
# Via Keycloak Admin Console
# Users → select user → toggle Enabled: OFF
```

### Reset Password

```bash
# Via Keycloak Admin Console
# Users → select user → Credentials → Reset Password
```

---

## Backup Configuration

### Manual Backup

```bash
# Basic backup (PostgreSQL + config)
make backup

# Full backup including DICOM storage
./scripts/backup.sh --include-dicom
```

### Automated Backups

Add to crontab:

```bash
# Edit crontab
crontab -e

# Add daily backup at 2 AM
0 2 * * * /opt/dicom-viewer/scripts/backup.sh >> /var/log/dicom-backup.log 2>&1

# Add weekly full backup on Sunday
0 3 * * 0 /opt/dicom-viewer/scripts/backup.sh --include-dicom >> /var/log/dicom-backup.log 2>&1
```

### Backup Retention

Default retention:
- 7 daily backups
- 4 weekly backups
- 12 monthly backups

Modify in `scripts/backup.sh`:

```bash
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=12
```

### Offsite Backup

Sync to remote storage:

```bash
# Example: rsync to backup server
rsync -avz /backup/ backup-server:/dicom-backups/

# Example: AWS S3
aws s3 sync /backup/ s3://your-bucket/dicom-backups/
```

---

## Monitoring and Alerts

### Access Grafana

1. Open https://imaging.your-domain.com/grafana
2. Login with credentials from `.env`

### Available Dashboards

- **Orthanc**: Studies, storage, API metrics
- **Keycloak**: Logins, sessions, errors
- **Nginx**: Requests, latency, rate limiting

### Configure Email Alerts

Edit `monitoring/alertmanager.yml`:

```yaml
global:
  smtp_smarthost: 'smtp.your-provider.com:587'
  smtp_from: 'alerts@your-domain.com'
  smtp_auth_username: 'alerts@your-domain.com'
  smtp_auth_password: 'your-password'

receivers:
  - name: 'critical-alerts'
    email_configs:
      - to: 'admin@your-domain.com'
```

### Configure Telegram Alerts

1. Create bot via @BotFather
2. Get chat ID
3. Edit `monitoring/alertmanager.yml`:

```yaml
receivers:
  - name: 'critical-alerts'
    telegram_configs:
      - bot_token: 'YOUR_BOT_TOKEN'
        chat_id: YOUR_CHAT_ID
```

### Restart Alertmanager

```bash
docker compose restart alertmanager
```

---

## Updating Components

### Check Current Versions

```bash
docker compose ps
docker compose images
```

### Update Procedure

```bash
# 1. Create backup
make backup

# 2. Pull new images
docker compose pull

# 3. Rebuild custom images
docker compose build

# 4. Restart services
docker compose up -d

# 5. Verify health
make status
```

### Rollback

```bash
# Stop services
make down

# Restore from backup
make restore BACKUP_FILE=/backup/dicom-backup-YYYY-MM-DD.tar.gz

# Start services
make up
```

---

## Disaster Recovery

### Complete Server Failure

1. **Provision new server** with same specs
2. **Install dependencies** (Docker, etc.)
3. **Clone repository**:
   ```bash
   git clone <repository> /opt/dicom-viewer
   ```
4. **Copy backup file** from offsite storage
5. **Restore**:
   ```bash
   cd /opt/dicom-viewer
   ./scripts/restore.sh /path/to/backup.tar.gz
   ```
6. **Update DNS** to point to new server
7. **Regenerate SSL certificates**:
   ```bash
   ./scripts/generate-certs.sh letsencrypt
   ```
8. **Verify all services**:
   ```bash
   make status
   ```

### Database Corruption

```bash
# Stop services
make down

# Restore PostgreSQL only
./scripts/restore.sh /backup/latest.tar.gz --postgres-only

# Start services
make up
```

### DICOM Storage Recovery

If DICOM storage is corrupted but database is intact:

1. Restore DICOM files from backup
2. Run Orthanc reconstruction:
   ```bash
   docker compose exec orthanc orthanc-recover
   ```

---

## Security Checklist

- [ ] Changed all default passwords in `.env`
- [ ] SSL certificates configured (not self-signed)
- [ ] Firewall rules: only 80/443 exposed
- [ ] Keycloak brute force protection enabled
- [ ] Regular backups configured and tested
- [ ] Monitoring alerts configured
- [ ] OS security updates automated
- [ ] Docker images regularly updated

---

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues and solutions.

---

## Support Contacts

- Technical Issues: [GitHub Issues]
- Documentation: [docs/](.)
- Emergency: admin@your-domain.com
