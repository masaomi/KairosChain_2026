#!/bin/bash

# Echoria EC2 Deployment Script
# This script automates deployment to an EC2 instance with Docker/Docker Compose

set -e

# Configuration
REPO_URL="${REPO_URL:-https://github.com/your-org/echoria.git}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/echoria}"
BRANCH="${BRANCH:-main}"
LOG_FILE="${DEPLOY_DIR}/deploy.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "${LOG_FILE}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "${LOG_FILE}"
    exit 1
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "${LOG_FILE}"
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    if ! command -v docker &> /dev/null; then
        error "Docker is not installed"
    fi

    if ! command -v docker-compose &> /dev/null; then
        error "Docker Compose is not installed"
    fi

    log "Prerequisites check passed"
}

# Setup deployment directory
setup_deploy_dir() {
    log "Setting up deployment directory..."

    if [ ! -d "${DEPLOY_DIR}" ]; then
        mkdir -p "${DEPLOY_DIR}"
        log "Created ${DEPLOY_DIR}"
    fi

    # Initialize log file
    touch "${LOG_FILE}"
}

# Clone or update repository
update_repository() {
    log "Updating repository from ${REPO_URL}..."

    if [ -d "${DEPLOY_DIR}/.git" ]; then
        cd "${DEPLOY_DIR}"
        git fetch origin
        git checkout "${BRANCH}"
        git pull origin "${BRANCH}"
        log "Repository updated"
    else
        rm -rf "${DEPLOY_DIR}"
        git clone --branch "${BRANCH}" "${REPO_URL}" "${DEPLOY_DIR}"
        log "Repository cloned"
    fi
}

# Load environment variables
load_environment() {
    log "Loading environment variables..."

    if [ -f "${DEPLOY_DIR}/.env.production" ]; then
        # shellcheck disable=SC1090
        source "${DEPLOY_DIR}/.env.production"
        log "Loaded .env.production"
    else
        warn ".env.production not found, using defaults"
    fi

    # Verify required variables
    if [ -z "${ANTHROPIC_API_KEY}" ]; then
        error "ANTHROPIC_API_KEY environment variable is not set"
    fi

    if [ -z "${SECRET_KEY_BASE}" ]; then
        warn "SECRET_KEY_BASE not set, generating a new one..."
        SECRET_KEY_BASE=$(openssl rand -hex 32)
        export SECRET_KEY_BASE
    fi
}

# Build Docker images
build_images() {
    log "Building Docker images..."

    cd "${DEPLOY_DIR}"
    docker-compose build --no-cache api web
    log "Docker images built successfully"
}

# Start services
start_services() {
    log "Starting Docker Compose services..."

    cd "${DEPLOY_DIR}"
    docker-compose up -d

    log "Services started"
    sleep 5
}

# Run database migrations
run_migrations() {
    log "Running database migrations..."

    cd "${DEPLOY_DIR}"
    docker-compose exec -T api bundle exec rails db:migrate
    log "Database migrations completed"
}

# Run health checks
health_check() {
    log "Running health checks..."

    local max_attempts=30
    local attempt=0

    # Check API health
    while [ $attempt -lt $max_attempts ]; do
        if docker-compose exec -T api curl -f http://localhost:3000/health >/dev/null 2>&1; then
            log "API health check passed"
            break
        fi
        attempt=$((attempt + 1))
        if [ $attempt -eq $max_attempts ]; then
            error "API health check failed after ${max_attempts} attempts"
        fi
        sleep 2
    done

    # Check nginx health
    if curl -f http://localhost/health >/dev/null 2>&1; then
        log "Nginx health check passed"
    else
        error "Nginx health check failed"
    fi
}

# Display status
show_status() {
    log "Deployment completed successfully!"
    echo ""
    echo -e "${GREEN}Service Status:${NC}"
    docker-compose ps
    echo ""
    echo -e "${GREEN}Echoria is running at: http://localhost${NC}"
    echo -e "${GREEN}API endpoint: http://localhost:3001${NC}"
    echo -e "${GREEN}Deployment log: ${LOG_FILE}${NC}"
}

# Rollback function
rollback() {
    error "Deployment failed. Rolling back..."
    cd "${DEPLOY_DIR}"
    docker-compose down
    git reset --hard HEAD~1
    docker-compose up -d
    error "Rollback completed"
}

# Cleanup old images
cleanup() {
    log "Cleaning up unused Docker images..."
    docker image prune -f --filter "until=72h" >/dev/null 2>&1
    log "Cleanup completed"
}

# Main execution
main() {
    log "Starting Echoria deployment..."
    log "Deployment directory: ${DEPLOY_DIR}"
    log "Branch: ${BRANCH}"

    check_prerequisites
    setup_deploy_dir
    update_repository
    load_environment
    build_images
    start_services
    run_migrations
    health_check
    cleanup
    show_status

    log "Deployment finished successfully!"
}

# Trap errors
trap rollback ERR

# Run main function
main "$@"
