# DICOM Web Viewer Stack

Production-ready DICOM imaging platform with web-based viewer, SSO authentication, and automated file import.

## Stack Components

| Component | Version | Purpose |
|-----------|---------|---------|
| **Orthanc** | 1.12.3 | DICOM server with DICOMweb API |
| **OHIF Viewer** | 3.9.0 | Web-based DICOM viewer (MPR, 3D) |
| **Keycloak** | 24.0 | Identity provider (SSO, RBAC) |
| **PostgreSQL** | 16 | Database for Orthanc & Keycloak |
| **Nginx** | 1.25 | Reverse proxy, TLS termination |
| **Prometheus** | 2.51 | Metrics collection |
| **Grafana** | 10.4 | Dashboards and alerting |
| **Loki** | 2.9 | Log aggregation |

## Quick Start

### Prerequisites

- Docker 24.0+
- Docker Compose 2.20+
- 8GB+ RAM
- 50GB+ storage (for DICOM data)

### Installation

```bash
# Clone and setup
git clone <repository>
cd dicom-viewer

# Run initial setup (creates .env, generates certs, pulls images)
./scripts/setup.sh

# Start the stack
make up

# Wait for services to be healthy (~2-3 minutes)
make status
```

### Access

| Service | URL | Credentials |
|---------|-----|-------------|
| **OHIF Viewer** | https://localhost | Keycloak login |
| **Keycloak Admin** | https://localhost/auth/admin | admin / (see .env) |
| **Grafana** | https://localhost/grafana | admin / (see .env) |
| **Orthanc API** | https://localhost/orthanc | Requires JWT |

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │                   Internet                   │
                    └─────────────────────┬───────────────────────┘
                                          │
                    ┌─────────────────────▼───────────────────────┐
                    │              Nginx (443/80)                  │
                    │         TLS Termination + Auth              │
                    └───┬─────────┬─────────┬─────────┬───────────┘
                        │         │         │         │
              ┌─────────▼───┐ ┌───▼───┐ ┌───▼───┐ ┌───▼───────┐
              │  Keycloak   │ │ OHIF  │ │Orthanc│ │  Grafana  │
              │    :8080    │ │  :80  │ │ :8042 │ │   :3000   │
              └──────┬──────┘ └───────┘ └───┬───┘ └─────┬─────┘
                     │                      │           │
              ┌──────▼──────────────────────▼───────────▼─────┐
              │              PostgreSQL :5432                  │
              └────────────────────────────────────────────────┘

  ┌─────────────────┐
  │    Importer     │─── watches ──> /inbox/{clinic_id}/
  │     :8080       │─── uploads ──> Orthanc (STOW-RS)
  └─────────────────┘
```

## Multi-Tenant Setup

Studies are isolated by clinic using Keycloak groups:

```
/clinics
├── denscan-central    # clinic_id: denscan-central
├── denscan-almaty     # clinic_id: denscan-almaty
└── partner-clinic     # clinic_id: partner-clinic
```

Users can only see studies from clinics they belong to.

## File Import

DICOM files are automatically imported via the watcher service:

1. Place files in `/data/inbox/{clinic_id}/{study_folder}/`
2. Wait 60 seconds (cooldown for file stability)
3. Files are uploaded to Orthanc with `InstitutionName = clinic_id`
4. On success: moved to `/data/processed/{clinic_id}/{date}/`
5. On failure: moved to `/data/failed/{clinic_id}/{date}/`

## Common Commands

```bash
# Start/stop
make up                 # Start all services
make down               # Stop all services
make restart            # Restart all services

# Logs
make logs               # Follow all logs
make logs-importer      # Follow importer logs

# Management
make add-user USERNAME=dr.smith EMAIL=smith@clinic.com CLINIC=denscan-central
make add-clinic CLINIC_ID=new-clinic CLINIC_NAME="New Clinic"
make backup             # Create backup
make restore BACKUP_FILE=backup.tar.gz

# Development
make up-dev             # Start with dev overrides
make shell-orthanc      # Shell into Orthanc container
make shell-db           # PostgreSQL CLI

# Status
make status             # Show service status
make test               # Run importer tests
```

## Configuration

### Environment Variables

Copy `.env.example` to `.env` and configure:

```bash
# Domain
DOMAIN=imaging.denscan.kz

# Passwords (auto-generated during setup)
POSTGRES_PASSWORD=...
KEYCLOAK_ADMIN_PASSWORD=...

# Paths
DICOM_STORAGE_PATH=/data/dicom
INBOX_PATH=/data/inbox
```

### SSL Certificates

```bash
# Development (self-signed)
./scripts/generate-certs.sh self-signed

# Production (Let's Encrypt)
./scripts/generate-certs.sh letsencrypt --domain imaging.denscan.kz
```

## Monitoring

- **Prometheus**: http://localhost:9090 (dev mode)
- **Grafana**: https://localhost/grafana
  - Orthanc Dashboard: studies, storage, imports
  - Keycloak Dashboard: logins, sessions
  - Nginx Dashboard: requests, latency

### Alerts

- `OrthancDown` - DICOM server unreachable
- `DICOMImportFailed` - Import failures
- `DiskSpaceLow` - Storage < 20%
- `CertificateExpiringSoon` - SSL expires in < 14 days

## Documentation

- [Admin Guide](docs/ADMIN.md) - Full setup and administration
- [User Guide](docs/USER.md) - For physicians/technicians
- [Architecture](docs/ARCHITECTURE.md) - Technical details
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues

## Security

- All traffic encrypted via TLS
- Authentication via Keycloak (OIDC/OAuth2)
- JWT validation for API access
- Role-based access control (RBAC)
- Clinic-based data isolation
- Rate limiting on API endpoints
- Security headers (HSTS, CSP, etc.)

## Backup & Recovery

```bash
# Daily backup (includes PostgreSQL, config, realm export)
make backup

# Include DICOM storage (large!)
./scripts/backup.sh --include-dicom

# Restore from backup
make restore BACKUP_FILE=/backup/dicom-backup-2024-01-15.tar.gz
```

## Support

- Issues: GitHub Issues
- Documentation: [docs/](docs/)
- Logs: `make logs`

## License

MIT License - See LICENSE file for details.
