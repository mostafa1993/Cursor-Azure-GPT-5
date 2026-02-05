#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${APP_DIR:-$SCRIPT_DIR}"
COMPOSE_SERVICE="flask-prod"

SERVICE_NAME="cloudflared-proxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

ensure_debian_based() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi

  if [ "${ID:-}" != "ubuntu" ] && [ "${ID:-}" != "debian" ]; then
    echo "Unsupported distro for auto-install. Please install dependencies manually." >&2
    exit 1
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    return
  fi

  ensure_debian_based
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/${ID}/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME:-stable} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
}

add_docker_group() {
  local target_user="${SUDO_USER:-$USER}"

  if ! getent group docker >/dev/null 2>&1; then
    sudo groupadd docker
  fi

  if id -nG "${target_user}" | grep -qw docker; then
    return
  fi

  sudo usermod -aG docker "${target_user}"
  echo "Added ${target_user} to docker group. Log out/in to use docker without sudo."
}

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    return
  fi

  ensure_debian_based
  sudo apt-get update
  sudo apt-get install -y curl gpg

  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared ${VERSION_CODENAME:-stable} main" \
    | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null

  sudo apt-get update
  sudo apt-get install -y cloudflared
}

ensure_env_file() {
  if [ -f "${APP_DIR}/.env" ]; then
    return
  fi

  if [ -f "${APP_DIR}/.env-example" ]; then
    cp "${APP_DIR}/.env-example" "${APP_DIR}/.env"
    echo "Copied .env-example to .env. Please edit it with your Azure keys."
    return
  fi

  echo "No .env or .env-example found. Please create ${APP_DIR}/.env." >&2
  exit 1
}

start_docker_compose() {
  install_docker
  add_docker_group

  if docker compose -f "${APP_DIR}/docker-compose.yml" up -d "${COMPOSE_SERVICE}"; then
    return
  fi

  sudo docker compose -f "${APP_DIR}/docker-compose.yml" up -d "${COMPOSE_SERVICE}"
}

install_cloudflared_service() {
  install_cloudflared

  sudo tee "${SERVICE_FILE}" >/dev/null <<'EOF'
[Unit]
Description=Cloudflared Quick Tunnel to local proxy on 8080
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --url http://localhost:8080 --logfile /var/log/cloudflared.log
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now "${SERVICE_NAME}"
}

ensure_tunnel_alias() {
  local alias_line
  alias_line="alias tunnelurl='sudo journalctl -u ${SERVICE_NAME} -n 200 | grep -oE \"https://[a-z0-9-]+\\.trycloudflare\\.com\" | tail -n1'"

  if [ -f /etc/profile.d/aliases.sh ] && sudo grep -q "alias tunnelurl=" /etc/profile.d/aliases.sh; then
    return
  fi

  echo "${alias_line}" | sudo tee -a /etc/profile.d/aliases.sh >/dev/null
}

print_tunnel_url() {
  local tunnel_url=""

  for _ in {1..30}; do
    tunnel_url=$(sudo journalctl -u "${SERVICE_NAME}" -n 200 | grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" | tail -n1 || true)
    if [ -n "${tunnel_url}" ]; then
      break
    fi
    sleep 1
  done

  if [ -n "${tunnel_url}" ]; then
    echo "Tunnel URL: ${tunnel_url}"
  else
    echo "Tunnel URL not found yet. Run: tunnelurl"
  fi
}

clone_repo
ensure_env_file
start_docker_compose
install_cloudflared_service
ensure_tunnel_alias
print_tunnel_url

echo "Setup complete."
