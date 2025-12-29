# =============================================================================
# DICOM Web Viewer Stack - Makefile
# =============================================================================
# Common commands for managing the DICOM Web Viewer stack
# =============================================================================

.PHONY: help up up-dev down restart logs logs-importer backup restore \
        add-user add-clinic shell-orthanc shell-db test status ssl-renew \
        clean pull build setup load-test-data

# Default target
.DEFAULT_GOAL := help

# Variables
COMPOSE_FILE := docker-compose.yml
COMPOSE_DEV_FILE := docker-compose.dev.yml
BACKUP_PATH ?= /backup

# =============================================================================
# Help
# =============================================================================

help: ## Show this help message
	@echo "DICOM Web Viewer Stack - Available Commands"
	@echo ""
	@echo "Usage: make [target] [VARIABLE=value]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make up                    Start all services"
	@echo "  make add-user USERNAME=dr.smith EMAIL=smith@clinic.com CLINIC=clinic-id"
	@echo "  make restore BACKUP_FILE=/backup/backup.tar.gz"

# =============================================================================
# Service Management
# =============================================================================

up: ## Start all services in production mode
	docker compose -f $(COMPOSE_FILE) up -d
	@echo ""
	@echo "Services starting... Run 'make status' to check."

up-dev: ## Start all services in development mode
	docker compose -f $(COMPOSE_FILE) -f $(COMPOSE_DEV_FILE) up -d
	@echo ""
	@echo "Development services starting..."
	@echo "  OHIF Viewer: http://localhost:3000"
	@echo "  Keycloak:    http://localhost:8080"
	@echo "  Orthanc:     http://localhost:8042"
	@echo "  Grafana:     http://localhost:3001"

down: ## Stop all services
	docker compose -f $(COMPOSE_FILE) down

restart: ## Restart all services
	docker compose -f $(COMPOSE_FILE) restart

stop: ## Stop all services without removing containers
	docker compose -f $(COMPOSE_FILE) stop

pull: ## Pull latest images
	docker compose -f $(COMPOSE_FILE) pull

build: ## Build custom images
	docker compose -f $(COMPOSE_FILE) build

# =============================================================================
# Logs
# =============================================================================

logs: ## Follow logs from all services
	docker compose -f $(COMPOSE_FILE) logs -f

logs-orthanc: ## Follow Orthanc logs
	docker compose -f $(COMPOSE_FILE) logs -f orthanc

logs-keycloak: ## Follow Keycloak logs
	docker compose -f $(COMPOSE_FILE) logs -f keycloak

logs-importer: ## Follow Importer logs
	docker compose -f $(COMPOSE_FILE) logs -f importer

logs-nginx: ## Follow Nginx logs
	docker compose -f $(COMPOSE_FILE) logs -f nginx

# =============================================================================
# Status and Health
# =============================================================================

status: ## Show status of all services
	@echo "=== Service Status ==="
	@docker compose -f $(COMPOSE_FILE) ps
	@echo ""
	@echo "=== Health Checks ==="
	@docker compose -f $(COMPOSE_FILE) ps --format "table {{.Name}}\t{{.Status}}" | grep -E "(healthy|unhealthy|starting)" || echo "Waiting for health checks..."
	@echo ""
	@echo "=== Resource Usage ==="
	@docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" $$(docker compose -f $(COMPOSE_FILE) ps -q) 2>/dev/null || true

ps: ## Alias for status
	@$(MAKE) status

health: ## Check health of all services
	@echo "Checking service health..."
	@docker compose -f $(COMPOSE_FILE) ps --format "{{.Name}}: {{.Status}}"

# =============================================================================
# User and Clinic Management
# =============================================================================

add-user: ## Add a new user (USERNAME, EMAIL, CLINIC required)
ifndef USERNAME
	$(error USERNAME is required. Usage: make add-user USERNAME=dr.smith EMAIL=smith@clinic.com CLINIC=clinic-id)
endif
ifndef EMAIL
	$(error EMAIL is required. Usage: make add-user USERNAME=dr.smith EMAIL=smith@clinic.com CLINIC=clinic-id)
endif
ifndef CLINIC
	$(error CLINIC is required. Usage: make add-user USERNAME=dr.smith EMAIL=smith@clinic.com CLINIC=clinic-id)
endif
	./scripts/add-user.sh $(USERNAME) $(EMAIL) $(CLINIC) $(ROLE_ARG)

add-clinic: ## Add a new clinic (CLINIC_ID, CLINIC_NAME required)
ifndef CLINIC_ID
	$(error CLINIC_ID is required. Usage: make add-clinic CLINIC_ID=new-clinic CLINIC_NAME="New Clinic")
endif
ifndef CLINIC_NAME
	$(error CLINIC_NAME is required. Usage: make add-clinic CLINIC_ID=new-clinic CLINIC_NAME="New Clinic")
endif
	./scripts/add-clinic.sh $(CLINIC_ID) "$(CLINIC_NAME)"

# =============================================================================
# Backup and Restore
# =============================================================================

backup: ## Create a backup of databases and configuration
	./scripts/backup.sh

backup-full: ## Create a full backup including DICOM storage
	./scripts/backup.sh --include-dicom

restore: ## Restore from a backup file (BACKUP_FILE required)
ifndef BACKUP_FILE
	$(error BACKUP_FILE is required. Usage: make restore BACKUP_FILE=/path/to/backup.tar.gz)
endif
	./scripts/restore.sh $(BACKUP_FILE)

# =============================================================================
# Shell Access
# =============================================================================

shell-orthanc: ## Open a shell in the Orthanc container
	docker compose -f $(COMPOSE_FILE) exec orthanc /bin/sh

shell-db: ## Open PostgreSQL CLI
	docker compose -f $(COMPOSE_FILE) exec postgres psql -U $${POSTGRES_USER:-dicom} -d $${POSTGRES_DB:-orthanc}

shell-keycloak: ## Open a shell in the Keycloak container
	docker compose -f $(COMPOSE_FILE) exec keycloak /bin/bash

shell-nginx: ## Open a shell in the Nginx container
	docker compose -f $(COMPOSE_FILE) exec nginx /bin/sh

shell-importer: ## Open a shell in the Importer container
	docker compose -f $(COMPOSE_FILE) exec importer /bin/bash

# =============================================================================
# Testing
# =============================================================================

test: ## Run importer tests
	docker compose -f $(COMPOSE_FILE) exec importer pytest -v

test-local: ## Run importer tests locally (requires Python environment)
	cd importer && python -m pytest -v

load-test-data: ## Load sample DICOM data for testing
	./scripts/load-test-data.sh

# =============================================================================
# SSL Certificates
# =============================================================================

ssl-renew: ## Renew SSL certificates
	./scripts/generate-certs.sh renew
	docker compose -f $(COMPOSE_FILE) restart nginx

ssl-self-signed: ## Generate self-signed certificates for development
	./scripts/generate-certs.sh self-signed
	docker compose -f $(COMPOSE_FILE) restart nginx

ssl-letsencrypt: ## Generate Let's Encrypt certificates (DOMAIN required)
ifndef DOMAIN
	$(error DOMAIN is required. Usage: make ssl-letsencrypt DOMAIN=imaging.example.com EMAIL=admin@example.com)
endif
	./scripts/generate-certs.sh letsencrypt --domain $(DOMAIN) $(if $(EMAIL),--email $(EMAIL),)
	docker compose -f $(COMPOSE_FILE) restart nginx

# =============================================================================
# Setup and Initialization
# =============================================================================

setup: ## Run initial setup (creates .env, directories, certs)
	./scripts/setup.sh

init: setup ## Alias for setup

# =============================================================================
# Cleanup
# =============================================================================

clean: ## Remove stopped containers and dangling images
	docker compose -f $(COMPOSE_FILE) down --remove-orphans
	docker image prune -f

clean-all: ## Remove all containers, volumes, and images (DANGEROUS!)
	@echo "WARNING: This will delete all data including DICOM storage!"
	@read -p "Are you sure? (yes/no): " confirm; \
	if [ "$$confirm" = "yes" ]; then \
		docker compose -f $(COMPOSE_FILE) down -v --remove-orphans; \
		docker image prune -af; \
	else \
		echo "Cancelled."; \
	fi

# =============================================================================
# Monitoring
# =============================================================================

grafana-password: ## Show Grafana admin password
	@grep GRAFANA_ADMIN_PASSWORD .env | cut -d= -f2

keycloak-password: ## Show Keycloak admin password
	@grep KEYCLOAK_ADMIN_PASSWORD .env | cut -d= -f2

# =============================================================================
# Development Helpers
# =============================================================================

dev-orthanc-api: ## Test Orthanc API (dev mode)
	curl -s http://localhost:8042/system | jq

dev-studies: ## List studies in Orthanc (dev mode)
	curl -s http://localhost:8042/studies | jq

dev-dicomweb: ## Test DICOMweb endpoint (dev mode)
	curl -s http://localhost:8042/dicom-web/studies | jq

# =============================================================================
# Version Info
# =============================================================================

version: ## Show version information
	@echo "DICOM Web Viewer Stack"
	@echo "======================"
	@echo ""
	@echo "Components:"
	@docker compose -f $(COMPOSE_FILE) images --format "table {{.Repository}}\t{{.Tag}}" 2>/dev/null || echo "Run 'make pull' first"
