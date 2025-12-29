# =============================================================================
# OHIF Viewer with Custom Configuration
# =============================================================================
# Multi-stage build for OHIF v3.9.0 with OIDC authentication
# =============================================================================

ARG OHIF_VERSION=v3.9.0

# =============================================================================
# Stage 1: Build OHIF from source (optional - for customization)
# =============================================================================
# FROM node:18-alpine AS builder
#
# ARG OHIF_VERSION
#
# WORKDIR /app
#
# # Clone OHIF Viewers
# RUN apk add --no-cache git && \
#     git clone --depth 1 --branch ${OHIF_VERSION} \
#     https://github.com/OHIF/Viewers.git .
#
# # Install dependencies
# RUN yarn install --frozen-lockfile
#
# # Build
# RUN yarn build

# =============================================================================
# Stage: Use pre-built OHIF image
# =============================================================================
FROM ohif/app:${OHIF_VERSION} AS ohif-base

# =============================================================================
# Stage: Production with nginx
# =============================================================================
FROM nginx:1.25-alpine

# Labels
LABEL maintainer="DICOM Stack Admin"
LABEL version="1.0.0"
LABEL description="OHIF Viewer v3.9.0 with Keycloak OIDC"

# Install curl for healthcheck
RUN apk add --no-cache curl

# Copy OHIF build from base image
COPY --from=ohif-base /usr/share/nginx/html /usr/share/nginx/html

# Copy custom configuration
COPY app-config.js /usr/share/nginx/html/app-config.js
COPY nginx.conf /etc/nginx/nginx.conf

# Create silent refresh page for OIDC
RUN cat > /usr/share/nginx/html/silent-refresh.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Silent Refresh</title>
</head>
<body>
    <script>
        parent.postMessage(location.href, location.origin);
    </script>
</body>
</html>
EOF

# Create callback page
RUN cat > /usr/share/nginx/html/callback.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Authentication Callback</title>
    <script>
        // Handle OIDC callback
        window.location.href = '/';
    </script>
</head>
<body>
    <p>Authenticating...</p>
</body>
</html>
EOF

# Set permissions
RUN chown -R nginx:nginx /usr/share/nginx/html && \
    chmod -R 755 /usr/share/nginx/html

# Health check
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -f http://localhost:80/ || exit 1

# Expose port
EXPOSE 80

# Start nginx
CMD ["nginx", "-g", "daemon off;"]
