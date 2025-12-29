# Architecture Overview

Technical architecture of the DICOM Web Viewer Stack.

## System Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                              INTERNET                                     │
└──────────────────────────────────┬───────────────────────────────────────┘
                                   │
                          ┌────────▼────────┐
                          │   DNS / CDN     │
                          │  (optional)     │
                          └────────┬────────┘
                                   │
┌──────────────────────────────────▼───────────────────────────────────────┐
│                           NGINX REVERSE PROXY                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │ TLS Termination │ Rate Limiting │ Auth Validation │ Load Balancing │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│           │              │              │              │                  │
│   ┌───────▼───────┐ ┌────▼────┐ ┌──────▼──────┐ ┌─────▼─────┐           │
│   │   /auth/*     │ │   /*    │ │  /orthanc/* │ │ /grafana/*│           │
│   └───────┬───────┘ └────┬────┘ └──────┬──────┘ └─────┬─────┘           │
└───────────┼──────────────┼─────────────┼──────────────┼──────────────────┘
            │              │             │              │
┌───────────▼──────────────▼─────────────▼──────────────▼──────────────────┐
│                           BACKEND NETWORK                                 │
│                                                                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │   KEYCLOAK   │  │    OHIF      │  │   ORTHANC    │  │   GRAFANA    │  │
│  │   :8080      │  │    :80       │  │    :8042     │  │    :3000     │  │
│  │              │  │              │  │    :4242     │  │              │  │
│  │  ┌────────┐  │  │  ┌────────┐  │  │  ┌────────┐  │  │  ┌────────┐  │  │
│  │  │ OAuth  │  │  │  │ React  │  │  │  │DICOMweb│  │  │  │Dashbrd │  │  │
│  │  │ OIDC   │  │  │  │ SPA    │  │  │  │ API    │  │  │  │        │  │  │
│  │  └────────┘  │  │  └────────┘  │  │  └────────┘  │  │  └────────┘  │  │
│  └──────┬───────┘  └──────────────┘  └──────┬───────┘  └──────┬───────┘  │
│         │                                   │                 │          │
│         │         ┌─────────────────────────┼─────────────────┤          │
│         │         │                         │                 │          │
│  ┌──────▼─────────▼─────────────────────────▼─────────────────▼───────┐  │
│  │                        POSTGRESQL :5432                             │  │
│  │  ┌──────────────────┐  ┌──────────────────┐                        │  │
│  │  │  keycloak DB     │  │   orthanc DB     │                        │  │
│  │  │  - users         │  │   - index        │                        │  │
│  │  │  - sessions      │  │   - metadata     │                        │  │
│  │  │  - clients       │  │   - changes      │                        │  │
│  │  └──────────────────┘  └──────────────────┘                        │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │   IMPORTER   │  │  PROMETHEUS  │  │     LOKI     │  │ ALERTMANAGER │  │
│  │    :8080     │  │    :9090     │  │    :3100     │  │    :9093     │  │
│  └──────┬───────┘  └──────────────┘  └──────────────┘  └──────────────┘  │
│         │                                                                 │
└─────────┼─────────────────────────────────────────────────────────────────┘
          │
┌─────────▼─────────────────────────────────────────────────────────────────┐
│                           FILE SYSTEM                                      │
│                                                                            │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐               │
│  │    /inbox/     │  │  /processed/   │  │   /dicom/      │               │
│  │  clinic-a/     │  │   clinic-a/    │  │   (storage)    │               │
│  │  clinic-b/     │  │   clinic-b/    │  │                │               │
│  └────────────────┘  └────────────────┘  └────────────────┘               │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

## Component Details

### Nginx Reverse Proxy

**Purpose**: TLS termination, routing, rate limiting, authentication validation

**Key Features**:
- SSL/TLS with modern cipher suites
- JWT validation via auth_request
- Rate limiting per endpoint
- Security headers (HSTS, CSP, etc.)
- WebSocket support for Keycloak admin

**Configuration Files**:
- `nginx/nginx.conf` - Main configuration
- `nginx/includes/security.conf` - Security headers
- `nginx/includes/rate-limit.conf` - Rate limiting zones
- `nginx/includes/proxy-params.conf` - Common proxy settings

### Keycloak Identity Provider

**Purpose**: Authentication, authorization, user management

**Key Features**:
- OAuth 2.0 / OpenID Connect
- PKCE flow for SPA
- Role-based access control
- Clinic-based group isolation
- Brute force protection

**Realm Structure**:
```
dicom (realm)
├── Clients
│   ├── ohif-viewer (public, PKCE)
│   ├── orthanc-api (confidential)
│   └── grafana (confidential)
├── Roles
│   ├── admin
│   ├── physician
│   └── technician
└── Groups
    └── clinics
        ├── clinic-a
        ├── clinic-b
        └── ...
```

**Token Claims**:
- `clinic_ids`: Array of clinic IDs from group membership
- `roles`: Realm roles
- `groups`: Group paths

### Orthanc DICOM Server

**Purpose**: DICOM storage, DICOMweb API, study management

**Key Features**:
- DICOMweb (WADO-RS, STOW-RS, QIDO-RS)
- PostgreSQL index storage
- Filesystem DICOM storage
- Lua scripting for access control
- Prometheus metrics

**Plugins**:
- PostgreSQL (index storage)
- DICOMweb (REST API)
- Authorization (JWT validation)

**API Endpoints**:
- `/dicom-web/studies` - QIDO-RS, STOW-RS
- `/dicom-web/studies/{uid}/series` - Series listing
- `/dicom-web/studies/{uid}/series/{uid}/instances` - Instance listing
- `/wado` - WADO-URI

### OHIF Viewer

**Purpose**: Web-based DICOM visualization

**Key Features**:
- Modern React-based viewer
- OIDC authentication
- DICOMweb integration
- MPR (multiplanar reconstruction)
- Measurement tools
- Hanging protocols

**Extensions**:
- Cornerstone (image rendering)
- Measurement Tracking
- DICOM SR
- DICOM PDF

### Importer Service

**Purpose**: Automated DICOM file import

**Workflow**:
```
1. File detected in /inbox/{clinic_id}/
         │
         ▼
2. Wait for cooldown (file stability)
         │
         ▼
3. Read DICOM, set InstitutionName = clinic_id
         │
         ▼
4. Upload via STOW-RS to Orthanc
         │
         ├── Success → Move to /processed/
         │
         └── Failure → Move to /failed/
                       Create error log
                       Send alert
```

**Metrics Exposed**:
- `dicom_imports_total` (counter)
- `dicom_import_duration_seconds` (histogram)
- `dicom_pending_imports` (gauge)

## Data Flow

### Authentication Flow

```
User                  OHIF              Keycloak           Orthanc
  │                    │                    │                 │
  │  1. Access /       │                    │                 │
  ├───────────────────>│                    │                 │
  │                    │                    │                 │
  │  2. Redirect       │                    │                 │
  │<───────────────────┤                    │                 │
  │                    │                    │                 │
  │  3. Login          │                    │                 │
  ├────────────────────┼───────────────────>│                 │
  │                    │                    │                 │
  │  4. Auth code      │                    │                 │
  │<───────────────────┼────────────────────┤                 │
  │                    │                    │                 │
  │  5. Redirect /callback                  │                 │
  ├───────────────────>│                    │                 │
  │                    │                    │                 │
  │                    │  6. Exchange code  │                 │
  │                    ├───────────────────>│                 │
  │                    │                    │                 │
  │                    │  7. Access token   │                 │
  │                    │<───────────────────┤                 │
  │                    │                    │                 │
  │  8. View studies   │                    │                 │
  │<───────────────────┤                    │                 │
  │                    │                    │                 │
  │                    │  9. API request (JWT)                │
  │                    ├──────────────────────────────────────>
  │                    │                    │                 │
  │                    │  10. Validate JWT  │                 │
  │                    │                    │<────────────────│
  │                    │                    │                 │
  │                    │  11. Data          │                 │
  │                    │<─────────────────────────────────────│
```

### DICOM Import Flow

```
DTX Studio          Inbox          Importer        Orthanc       PostgreSQL
    │                 │                │              │              │
    │  1. Export      │                │              │              │
    ├────────────────>│                │              │              │
    │                 │                │              │              │
    │                 │  2. inotify    │              │              │
    │                 ├───────────────>│              │              │
    │                 │                │              │              │
    │                 │  3. Wait 60s   │              │              │
    │                 │                │              │              │
    │                 │  4. Read files │              │              │
    │                 │<───────────────┤              │              │
    │                 │                │              │              │
    │                 │                │  5. STOW-RS  │              │
    │                 │                ├─────────────>│              │
    │                 │                │              │              │
    │                 │                │              │  6. Index    │
    │                 │                │              ├─────────────>│
    │                 │                │              │              │
    │                 │                │  7. 200 OK   │              │
    │                 │                │<─────────────┤              │
    │                 │                │              │              │
    │                 │  8. Move to    │              │              │
    │                 │     processed  │              │              │
    │                 │<───────────────┤              │              │
```

## Security Architecture

### Network Isolation

```
┌─────────────────────────────────────────────────────────────────┐
│  FRONTEND NETWORK (172.28.0.0/16)                               │
│  ┌─────────┐                                                    │
│  │  Nginx  │◄──────── Internet (ports 80, 443)                  │
│  └────┬────┘                                                    │
└───────┼─────────────────────────────────────────────────────────┘
        │
┌───────▼─────────────────────────────────────────────────────────┐
│  BACKEND NETWORK (172.29.0.0/16) - INTERNAL ONLY                │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐           │
│  │ Keycloak │ │   OHIF   │ │  Orthanc │ │ Postgres │           │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘           │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐           │
│  │ Importer │ │Prometheus│ │  Grafana │ │   Loki   │           │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘           │
└─────────────────────────────────────────────────────────────────┘
```

### Authentication Layers

1. **Nginx**: TLS termination, rate limiting
2. **Keycloak**: OAuth2/OIDC authentication
3. **Orthanc**: JWT validation, clinic filtering
4. **PostgreSQL**: Credentials in environment variables

## Scalability Considerations

### Horizontal Scaling

Components that can be scaled horizontally:
- OHIF (stateless)
- Orthanc (with shared PostgreSQL)
- Nginx (with load balancer)

### Vertical Scaling

Components requiring vertical scaling:
- PostgreSQL (or replicas)
- DICOM storage (larger volumes)

### Capacity Planning

| Metric | Calculation |
|--------|-------------|
| Storage | 20 studies/day × 500MB × 365 days = ~3.6 TB/year |
| Database | ~100 KB/study × 7300 studies = ~730 MB/year |
| Memory | Base 4GB + 1GB per concurrent user |

## Disaster Recovery

### Backup Components

| Component | Method | Frequency |
|-----------|--------|-----------|
| PostgreSQL | pg_dump | Daily |
| DICOM Storage | rsync/restic | Daily (incremental) |
| Configuration | tar archive | With every change |
| Keycloak Realm | Export | Daily |

### Recovery Objectives

| Metric | Target |
|--------|--------|
| RPO (Recovery Point Objective) | 24 hours |
| RTO (Recovery Time Objective) | 4 hours |
