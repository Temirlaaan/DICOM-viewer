# Troubleshooting Guide

Common issues and solutions for the DICOM Web Viewer Stack.

## Table of Contents

1. [Service Issues](#service-issues)
2. [Authentication Issues](#authentication-issues)
3. [DICOM Import Issues](#dicom-import-issues)
4. [Viewer Issues](#viewer-issues)
5. [Performance Issues](#performance-issues)
6. [SSL Certificate Issues](#ssl-certificate-issues)
7. [Database Issues](#database-issues)
8. [Monitoring Issues](#monitoring-issues)

---

## Service Issues

### Services Won't Start

**Symptoms**: `docker compose up` fails or services exit immediately

**Check service status**:
```bash
docker compose ps
docker compose logs <service-name>
```

**Common causes**:

1. **Port already in use**
   ```bash
   # Find what's using the port
   sudo lsof -i :80
   sudo lsof -i :443

   # Stop conflicting service
   sudo systemctl stop apache2  # or nginx
   ```

2. **Insufficient memory**
   ```bash
   # Check memory
   free -h

   # Reduce memory limits in .env
   KEYCLOAK_MEMORY_LIMIT=512m
   ORTHANC_MEMORY_LIMIT=1g
   ```

3. **Missing .env file**
   ```bash
   # Create from example
   cp .env.example .env
   # Edit and set required values
   nano .env
   ```

4. **Docker not running**
   ```bash
   sudo systemctl start docker
   ```

### Container Keeps Restarting

**Check logs for the specific service**:
```bash
docker compose logs -f --tail=100 <service-name>
```

**Common causes**:

1. **Database not ready** (Orthanc, Keycloak)
   - Wait longer, or check postgres logs

2. **Wrong configuration**
   - Verify config files syntax
   ```bash
   # Check JSON syntax
   python3 -m json.tool orthanc/orthanc.json
   ```

3. **Permission issues**
   ```bash
   # Fix ownership
   sudo chown -R 1000:1000 data/
   ```

---

## Authentication Issues

### Can't Log In

**Symptoms**: Login page appears but credentials rejected

**Solutions**:

1. **Check Keycloak is healthy**
   ```bash
   docker compose ps keycloak
   docker compose logs keycloak | grep -i error
   ```

2. **Verify user exists in Keycloak**
   - Access Keycloak admin: https://your-domain/auth/admin
   - Go to Users, search for username

3. **Check user is enabled**
   - In Keycloak admin, verify user's Enabled = ON

4. **Check realm is correct**
   - Should be "dicom" realm, not "master"

5. **Reset password**
   ```bash
   ./scripts/add-user.sh <username> <email> <clinic> --password "NewTemp123!"
   ```

### Token Errors

**Symptoms**: "Invalid token" or "Token expired" errors

**Solutions**:

1. **Clear browser cache and cookies**

2. **Check time synchronization**
   ```bash
   # Server time
   date

   # Sync time
   sudo timedatectl set-ntp on
   ```

3. **Check Keycloak token settings**
   - Access Token Lifespan: 5 minutes
   - SSO Session Idle: 8 hours

### User Can't See Studies

**Symptoms**: User logs in but study list is empty

**Solutions**:

1. **Verify clinic membership**
   - In Keycloak admin: Users → Select user → Groups
   - Should be member of `/clinics/<clinic-id>`

2. **Verify clinic_ids attribute**
   - In Keycloak admin: Users → Select user → Attributes
   - Should have `clinic_ids` with correct values

3. **Check study InstitutionName**
   ```bash
   # Query Orthanc for study metadata
   curl -u $ORTHANC_USERNAME:$ORTHANC_PASSWORD \
     http://localhost:8042/studies/<study-id> | jq .MainDicomTags.InstitutionName
   ```

---

## DICOM Import Issues

### Files Not Being Imported

**Symptoms**: Files in inbox but not appearing in viewer

**Check importer logs**:
```bash
docker compose logs -f importer
```

**Solutions**:

1. **Verify folder structure**
   ```
   /inbox/
     clinic-id/           ← Must match Keycloak group
       study-folder/      ← Any name
         *.dcm            ← DICOM files
   ```

2. **Check cooldown period**
   - Default: 60 seconds after last file modification
   - Reduce for testing: `COOLDOWN_SECONDS=10` in .env

3. **Verify DICOM files are valid**
   ```bash
   # Test with dcmdump (from dcmtk)
   dcmdump /data/inbox/clinic-id/study/file.dcm
   ```

4. **Check importer can reach Orthanc**
   ```bash
   docker compose exec importer curl http://orthanc:8042/system
   ```

### Import Fails with Errors

**Check error logs in failed folder**:
```bash
cat /data/failed/clinic-id/date/study.error.json
```

**Common errors**:

1. **"Invalid DICOM file"**
   - File is corrupted or not DICOM format
   - Check file with `dcmdump`

2. **"STOW-RS failed: 413"**
   - File too large
   - Increase `client_max_body_size` in nginx

3. **"Connection refused"**
   - Orthanc not running
   - Check: `docker compose ps orthanc`

4. **"Authentication failed"**
   - Invalid client secret
   - Check Keycloak client configuration

---

## Viewer Issues

### Images Not Loading

**Symptoms**: Viewer shows empty or loading spinner

**Solutions**:

1. **Check browser console for errors**
   - Press F12 → Console tab

2. **Verify DICOMweb endpoint**
   ```bash
   curl -H "Authorization: Bearer $TOKEN" \
     https://your-domain/dicom-web/studies
   ```

3. **Check CORS configuration**
   - Verify nginx CORS headers
   - Check OHIF app-config.js URLs

4. **Check Orthanc DICOMweb plugin**
   ```bash
   docker compose exec orthanc curl http://localhost:8042/dicom-web/studies
   ```

### MPR/3D Not Working

**Symptoms**: MPR or 3D mode shows error

**Solutions**:

1. **Check study compatibility**
   - MPR requires volumetric data (CT, MR)
   - Single images don't support MPR

2. **Browser requirements**
   - WebGL support required
   - Try: `chrome://gpu` to check

3. **Memory issues**
   - Large volumes need more browser memory
   - Close other tabs

---

## Performance Issues

### Slow Study Loading

**Solutions**:

1. **Check network latency**
   ```bash
   ping your-domain.com
   ```

2. **Enable caching in nginx**
   - Already configured for static assets

3. **Reduce concurrent requests**
   ```javascript
   // In app-config.js
   maxNumRequests: {
     interaction: 50,
     thumbnail: 25,
     prefetch: 10,
   }
   ```

4. **Check Orthanc performance**
   ```bash
   # Query Orthanc metrics
   curl http://localhost:8042/metrics | grep orthanc_
   ```

### High CPU/Memory Usage

**Check container resource usage**:
```bash
docker stats
```

**Solutions**:

1. **Increase resource limits** in `.env`

2. **Optimize PostgreSQL**
   ```sql
   -- Connect to postgres
   docker compose exec postgres psql -U dicom -d orthanc

   -- Vacuum and analyze
   VACUUM ANALYZE;
   ```

3. **Clear old data**
   ```bash
   # Remove old studies via Orthanc API
   curl -X DELETE http://localhost:8042/studies/<old-study-id>
   ```

---

## SSL Certificate Issues

### Certificate Expired

**Symptoms**: Browser shows security warning

**Solutions**:

1. **Renew Let's Encrypt**
   ```bash
   ./scripts/generate-certs.sh renew
   docker compose restart nginx
   ```

2. **Generate new self-signed (dev only)**
   ```bash
   ./scripts/generate-certs.sh self-signed --force
   docker compose restart nginx
   ```

### Certificate Not Trusted

**For self-signed certificates**:
- This is expected behavior
- Use Let's Encrypt for production

**For Let's Encrypt**:
1. Check domain DNS is correct
2. Ensure port 80 is accessible for challenge
3. Check certbot logs: `/var/log/letsencrypt/letsencrypt.log`

---

## Database Issues

### Database Connection Failed

**Check postgres status**:
```bash
docker compose ps postgres
docker compose logs postgres
```

**Solutions**:

1. **Wait for postgres to initialize** (first run)

2. **Check credentials** in `.env` match

3. **Restart postgres**
   ```bash
   docker compose restart postgres
   ```

### Database Corruption

**Symptoms**: Errors about corrupt tables or indexes

**Solutions**:

1. **Restore from backup**
   ```bash
   ./scripts/restore.sh /backup/latest.tar.gz --postgres-only
   ```

2. **Reindex Orthanc**
   ```bash
   docker compose exec postgres psql -U dicom -d orthanc -c "REINDEX DATABASE orthanc;"
   ```

---

## Monitoring Issues

### Prometheus Not Scraping

**Check targets**:
- Access http://localhost:9090/targets (dev mode)
- Or https://your-domain/grafana → Explore → Prometheus

**Solutions**:

1. **Verify service is exposing metrics**
   ```bash
   docker compose exec orthanc curl http://localhost:8042/metrics
   ```

2. **Check prometheus.yml targets**

3. **Restart prometheus**
   ```bash
   docker compose restart prometheus
   ```

### Grafana Dashboard Empty

**Solutions**:

1. **Check data source**
   - Configuration → Data Sources → Prometheus → Test

2. **Check time range**
   - May need to expand range if just started

3. **Verify dashboard queries**
   - Edit panel → Check query syntax

---

## Quick Diagnostic Commands

```bash
# Overall status
make status

# Check all logs
make logs

# Check specific service
docker compose logs -f --tail=100 <service>

# Shell into container
docker compose exec <service> /bin/sh

# Database shell
docker compose exec postgres psql -U dicom -d orthanc

# Check disk space
df -h

# Check Docker disk usage
docker system df

# Restart all services
docker compose restart

# Full reset (caution: deletes data volumes)
docker compose down -v
docker compose up -d
```

---

## Getting Help

If you can't resolve the issue:

1. **Collect logs**
   ```bash
   docker compose logs > logs.txt 2>&1
   ```

2. **Note the exact error message**

3. **Check system resources**
   ```bash
   free -h
   df -h
   docker stats --no-stream
   ```

4. **Contact support** with:
   - Error message
   - Logs
   - Steps to reproduce
   - System information
