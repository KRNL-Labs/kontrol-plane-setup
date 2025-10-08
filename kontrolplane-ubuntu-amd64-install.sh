#!/usr/bin/env bash
set -euo pipefail

# ---------------- Defaults (override via flags) ----------------
SERVICE_NAME="kontrolplane"
SERVICE_USER="kontrolplane"        # run the service under this user
# S3 public URLs for binary & config
BIN_S3="s3://krnl-gvisor-releases-public/releases/1.0.2/rpc-amd64"
CFG_S3="s3://krnl-gvisor-releases-public/releases/1.0.2/config.toml"
S3_REGION=""

SET_DEFAULT_RUNTIME=false
CREATE_SERVICE=true                 # create the systemd service by default

# Paths
ETC_DIR="/etc/kontrolplane"
LOG_DIR="/home/kontrolplane/log"
LOG_FILE="${LOG_DIR}/kontrolplane.log"
BIN_LOCAL="${ETC_DIR}/kontrolplane-amd64"

# ---------------- Arg parsing ----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-s3) BIN_S3="$2"; shift 2 ;;
    --cfg-s3) CFG_S3="$2"; shift 2 ;;
    --s3-region) S3_REGION="$2"; shift 2 ;;
    --set-default-runtime) SET_DEFAULT_RUNTIME=true; shift 1 ;;
    --create-service|--create-kontrolplane) CREATE_SERVICE=true; shift 1 ;;
    --service-user|--kp-user) SERVICE_USER="$2"; shift 2 ;;
    --service-name) SERVICE_NAME="$2"; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
Usage:
  bash setup.sh \
    --bin-s3 s3://bucket/path/rpc-amd64 \
    [--cfg-s3 s3://bucket/path/config.toml] \
    [--s3-region ap-southeast-1] \
    [--set-default-runtime] \
    [--create-service] \
    [--service-user kontrolplane] \
    [--service-name kontrolplane]
Run this script as root.
USAGE
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$BIN_S3" ]] || { echo "Missing --bin-s3"; exit 1; }

# ---------------- Helpers ----------------
have_cmd(){ command -v "$1" >/dev/null 2>&1; }
arch(){ uname -m; }

ensure_cosign() {
  if have_cmd cosign; then return 0; fi
  u="https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"
  curl -fsSL "$u" -o /usr/local/bin/cosign
  chmod +x /usr/local/bin/cosign
}

s3_to_https() {
  local uri="$1"
  local rest="${uri#s3://}"
  local bucket="${rest%%/*}"
  local key="${rest#*/}"
  key="${key// /%20}"
  if [[ -n "$S3_REGION" ]]; then
    echo "https://${bucket}.s3.${S3_REGION}.amazonaws.com/${key}"
  else
    echo "https://${bucket}.s3.amazonaws.com/${key}"
  fi
}

fetch_s3_to() {
  local s3="$1" dst="$2"
  local url; url="$(s3_to_https "$s3")"
  echo "[Fetch] $url"
  wget -qO "$dst" "$url" || {
    echo "Download failed from $url (ensure PUBLIC READ)." >&2
    return 1
  }
}

ensure_acl() {
  if ! have_cmd setfacl; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y acl >/dev/null 2>&1 || true
  fi
}

ensure_user_exists() {
  local user="$1"
  if ! id -u "$user" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/home/$user" --shell /usr/sbin/nologin "$user"
  fi
}

ensure_service_user_and_dirs() {
  local user="$1"
  # Create service user if missing
  ensure_user_exists "$user"

  # Add to docker group
  if getent group docker >/dev/null 2>&1; then
    usermod -aG docker "$user"
  else
    echo "WARNING: group 'docker' not present (Docker will create it)."
  fi

  # Directories
  mkdir -p "$ETC_DIR" "$LOG_DIR"
  touch "$LOG_FILE"
  chown -R "$user":"$user" "$ETC_DIR" "$LOG_DIR"
  chmod 0750 "$ETC_DIR" "$LOG_DIR"
  chmod 755 "$LOG_FILE"

  ensure_acl
  setfacl -d -m "u:${user}:rwX" "$LOG_DIR" || true

  # ---------------- Resources folder (owned by 'kontrolplane') ----------------
  ensure_user_exists "kontrolplane"
  mkdir -p "${ETC_DIR}/resources"
  chown -R "$user":"$user" "${ETC_DIR}/resources"
  chmod 0750 "${ETC_DIR}/resources"
  ensure_acl
  setfacl -d -m "u:kontrolplane:rwX" "${ETC_DIR}/resources" || true
}

# ---------------- Base packages ----------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io curl wget ca-certificates coreutils
ensure_cosign || true

# ---------------- gVisor ----------------
RUNSC_URL="https://storage.googleapis.com/gvisor/releases/release/latest/x86_64/runsc"
SHIM_URL="https://storage.googleapis.com/gvisor/releases/release/latest/x86_64/containerd-shim-runsc-v1"
curl -fsSL "$RUNSC_URL" -o /usr/local/bin/runsc
curl -fsSL "$SHIM_URL" -o /usr/local/bin/containerd-shim-runsc-v1
chmod +x /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1

# ---------------- Docker runtime ----------------
mkdir -p /etc/docker
if $SET_DEFAULT_RUNTIME; then
  tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "default-runtime": "runsc",
  "runtimes": { "runsc": { "path": "/usr/local/bin/runsc" } }
}
EOF
else
  tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "runtimes": { "runsc": { "path": "/usr/local/bin/runsc" } }
}
EOF
fi
systemctl restart docker || true

# ---------------- Install binary ----------------
echo "[Install] ${BIN_LOCAL}"
TMP_BIN="$(mktemp)"
fetch_s3_to "$BIN_S3" "$TMP_BIN"
mkdir -p "$ETC_DIR"
install -m 0755 -T "$TMP_BIN" "$BIN_LOCAL"
rm -f "$TMP_BIN"

# ---------------- Install config ----------------
mkdir -p "$ETC_DIR"
if [[ -n "${CFG_S3}" ]]; then
  echo "[Config] ${ETC_DIR}/config.toml"
  TMP_CFG="$(mktemp)"
  fetch_s3_to "$CFG_S3" "$TMP_CFG"
  install -D -m 0644 "$TMP_CFG" "${ETC_DIR}/config.toml"
  rm -f "$TMP_CFG"
fi



# ---------------- systemd service ----------------
if $CREATE_SERVICE; then
  ensure_service_user_and_dirs "$SERVICE_USER"

  START_CMD="${BIN_LOCAL} -log=debug >> ${LOG_FILE} 2>&1"

  tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<EOF
[Unit]
Description=${SERVICE_NAME} service
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=${SERVICE_USER}
WorkingDirectory=${ETC_DIR}
SupplementaryGroups=docker
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/bin/bash -c '${START_CMD}'
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service"
  systemctl restart "${SERVICE_NAME}.service" || systemctl start "${SERVICE_NAME}.service"
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
fi

echo "DONE ✓  Binary: ${BIN_LOCAL}  Config: ${ETC_DIR}/config.toml (if provided)  Log: ${LOG_FILE}  Service: ${SERVICE_NAME} (user=${SERVICE_USER})"
