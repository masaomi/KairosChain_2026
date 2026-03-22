#!/bin/bash
# =============================================================================
# KairosChain Meeting Place — EC2 Setup Script
# Target: Amazon Linux 2023 (t3.small)
# Usage:  scp this script to EC2, then: bash ec2-setup.sh
# =============================================================================
set -euo pipefail

echo "=== KairosChain Meeting Place — EC2 Setup ==="

# -------------------------------------------------------------------------
# 1. Install Docker + Docker Compose plugin
# -------------------------------------------------------------------------
echo "[1/5] Installing Docker..."
sudo dnf update -y -q
sudo dnf install -y -q docker git
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker "$USER"

# Docker Compose plugin
echo "[1/5] Installing Docker Compose plugin..."
DOCKER_CLI_PLUGINS="${DOCKER_CLI_PLUGINS:-$HOME/.docker/cli-plugins}"
mkdir -p "$DOCKER_CLI_PLUGINS"
COMPOSE_VERSION=$(curl -sL https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
ARCH=$(uname -m)
curl -SL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCH}" \
  -o "$DOCKER_CLI_PLUGINS/docker-compose"
chmod +x "$DOCKER_CLI_PLUGINS/docker-compose"
echo "  Docker Compose ${COMPOSE_VERSION} installed."

# -------------------------------------------------------------------------
# 2. Clone repository
# -------------------------------------------------------------------------
echo "[2/5] Cloning repository..."
REPO_DIR="$HOME/KairosChain_2026"
if [ -d "$REPO_DIR" ]; then
  echo "  Repository already exists at $REPO_DIR. Pulling latest..."
  cd "$REPO_DIR" && git pull
else
  git clone https://github.com/masaomi/KairosChain_2026.git "$REPO_DIR"
fi
cd "$REPO_DIR/docker"

# -------------------------------------------------------------------------
# 3. Generate .env
# -------------------------------------------------------------------------
echo "[3/5] Generating .env..."
if [ -f .env ]; then
  echo "  .env already exists. Skipping generation."
else
  PG_PASS=$(openssl rand -base64 32 | tr -d '/+=')
  cat > .env <<EOF
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=kairoschain
POSTGRES_USER=kairoschain
EOF
  chmod 600 .env
  echo "  .env created with generated password."
fi

# -------------------------------------------------------------------------
# 4. Build and start
# -------------------------------------------------------------------------
echo "[4/5] Building and starting containers..."
# Use newgrp to pick up docker group without re-login
sg docker -c "docker compose -f docker-compose.prod.yml build"
sg docker -c "docker compose -f docker-compose.prod.yml up -d"

# -------------------------------------------------------------------------
# 5. Verify
# -------------------------------------------------------------------------
echo "[5/5] Waiting for services to start..."
sleep 15

if curl -sf http://localhost:8080/health > /dev/null 2>&1; then
  echo ""
  echo "=== Setup Complete ==="
  echo ""
  echo "Health check: OK"
  sg docker -c "docker exec kairos-meeting-place cat /app/.kairos/.admin_token" && echo ""
  echo ""
  echo "Admin token saved above. Store it securely."
  echo ""
  echo "Next steps:"
  echo "  1. Point DNS A record for meeting.kairoschain.io -> $(curl -s http://checkip.amazonaws.com)"
  echo "  2. Wait for DNS propagation"
  echo "  3. Caddy will auto-obtain TLS certificate on first HTTPS request"
  echo "  4. Test: curl https://meeting.kairoschain.io/health"
else
  echo ""
  echo "=== Health check failed ==="
  echo "Check logs: docker compose -f docker-compose.prod.yml logs"
fi
