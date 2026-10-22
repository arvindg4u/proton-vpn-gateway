#!/usr/bin/env bash
# One-shot setup for a fresh VM: Proton exit via gluetun + Claude Code proxy
# + OpenCode/Claude Code routed through it.
#
#   sudo bash scripts/setup-new-vm.sh
#   sudo bash scripts/setup-new-vm.sh --key "<proton private key>"
#
# Re-runnable: every step is skipped when already done.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATEWAY_DIR="$HOME/proton-vpn-gateway"
TOOLKIT_DIR="$HOME/tor-proxy-toolkit"
USER_NAME="${SUDO_USER:-$(id -un)}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

PROTON_KEY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --key) PROTON_KEY="$2"; shift 2 ;;
    --key=*) PROTON_KEY="${1#*=}"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ── 1. Docker ────────────────────────────────────────────────────────────────
log "Docker"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
if ! id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx docker; then
  usermod -aG docker "$USER_NAME"
  warn "added $USER_NAME to the docker group - log out/in (or 'newgrp docker') for it to take effect"
fi

# ── 2. Proton key + gluetun ─────────────────────────────────────────────────
log "gluetun (Proton exit)"
mkdir -p "$GATEWAY_DIR/gluetun"
cp -n "$REPO_DIR/gluetun/docker-compose.yml" "$GATEWAY_DIR/gluetun/" 2>/dev/null || true
cp -n "$REPO_DIR/gluetun/rotate_on_429.py" "$GATEWAY_DIR/gluetun/" 2>/dev/null || true
chmod +x "$GATEWAY_DIR/gluetun/rotate_on_429.py"

if [ -z "$PROTON_KEY" ] && [ -f "$GATEWAY_DIR/gluetun/.env" ]; then
  PROTON_KEY=$(grep '^WIREGUARD_PRIVATE_KEY=' "$GATEWAY_DIR/gluetun/.env" | cut -d= -f2-)
fi
if [ -z "$PROTON_KEY" ]; then
  [ -t 0 ] || die "no Proton key given: pass --key \"<base64 private key>\""
  read -r -p "Proton WireGuard private key (PrivateKey = ...): " PROTON_KEY
fi
[ -n "$PROTON_KEY" ] || die "Proton private key is required"
umask 077
cat > "$GATEWAY_DIR/gluetun/.env" <<EOF
WIREGUARD_PRIVATE_KEY=$PROTON_KEY
SERVER_COUNTRIES=Netherlands
EOF
chmod 600 "$GATEWAY_DIR/gluetun/.env"

cd "$GATEWAY_DIR/gluetun"
docker compose up -d
for i in $(seq 1 24); do
  if [ "$(docker inspect gluetun --format '{{.State.Health.Status}}' 2>/dev/null)" = "healthy" ]; then break; fi
  sleep 5
done
docker ps --filter name=gluetun --format 'gluetun: {{.Status}}'
curl -s --max-time 20 -x http://127.0.0.1:8888 https://ifconfig.me | sed 's/^/exit IP: /' || warn "proxy not answering yet"

# ── 3. Bun (the proxy's upstream transport) ─────────────────────────────────
log "Bun runtime (required by the claude-code-proxy upstream transport)"
if ! command -v bun >/dev/null 2>&1; then
  if command -v npm >/dev/null 2>&1; then
    npm install -g bun
  else
    curl -fsSL https://bun.sh/install | bash
    export BUN_INSTALL="$HOME/.bun/bin"
    export PATH="$BUN_INSTALL:$PATH"
  fi
fi
bun --version | sed 's/^/bun: /'

# ── 4. claude-code-proxy (tor-proxy-toolkit) ────────────────────────────────
log "claude-code-proxy"
if [ ! -d "$TOOLKIT_DIR/.git" ]; then
  git clone https://github.com/arvindg4u/tor-proxy-toolkit.git "$TOOLKIT_DIR"
fi
PROXY_DIR="$TOOLKIT_DIR/claude-code-proxy"
cd "$PROXY_DIR"
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q -r requirements.txt

# models -> minimax (1M context, the free tier's widest)
[ -f .env ] || cp .env.example .env
python3 - <<'PY'
import re, secrets, string, pathlib
p = pathlib.Path(".env")
s = p.read_text()
for var in ("BIG_MODEL", "MIDDLE_MODEL", "SMALL_MODEL"):
    s = re.sub(rf"^{var}=.*$", f"{var}=minimax-m3.1-flash-free", s, flags=re.M)
s = re.sub(r"^OPENCODE_SESSION_ID=.*$", "", s, flags=re.M)
sid = "ses_" + "".join(secrets.choice("0123456789abcdef") for _ in range(12)) \
      + "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(14))
s += f"\nOPENCODE_SESSION_ID={sid}\n"
s += "HTTPS_PROXY=http://127.0.0.1:8888\nHTTP_PROXY=http://127.0.0.1:8888\n"
s += "NO_PROXY=localhost,127.0.0.1,::1\nHOST=127.0.0.1\nPORT=4013\n"
p.write_text(s)
print("proxy .env configured (minimax, session id, proton proxy env)")
PY

# ── 5. systemd user services ────────────────────────────────────────────────
log "systemd services"
mkdir -p "$HOME/.config/systemd/user"
cp "$REPO_DIR/systemd/claude-code-proxy.service" "$HOME/.config/systemd/user/"
cp "$REPO_DIR/systemd/proton-rotate.service" "$HOME/.config/systemd/user/"
sed -i "s#/home/ubuntu/proton-vpn-gateway#${GATEWAY_DIR}#g" "$HOME/.config/systemd/user/proton-rotate.service"
sed -i "s#/home/ubuntu/tor-proxy-toolkit#${TOOLKIT_DIR}#g" "$HOME/.config/systemd/user/claude-code-proxy.service"
loginctl enable-linger "$USER_NAME" 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable --now claude-code-proxy.service
systemctl --user enable --now proton-rotate.service
sleep 4
systemctl --user is-active claude-code-proxy.service proton-rotate.service

# ── 6. OpenCode provider (routes the CLI through the proxy) ─────────────────
log "OpenCode"
mkdir -p "$HOME/.config/opencode"
if [ -f "$HOME/.config/opencode/opencode.json" ]; then
  cp "$HOME/.config/opencode/opencode.json" "$HOME/.config/opencode/opencode.json.bak"
  warn "existing opencode.json backed up to opencode.json.bak - merge the zenproxy provider by hand"
else
  cp "$REPO_DIR/opencode/opencode.json" "$HOME/.config/opencode/opencode.json"
fi

# Kilo Code gateway key: opencode's built-in "kilo" provider reads KILO_API_KEY
KILO_KEY=""
if [ -f "$HOME/.config/opencode/opencode.env" ]; then
  KILO_KEY=$(grep '^KILO_API_KEY=' "$HOME/.config/opencode/opencode.env" | cut -d= -f2-)
fi
if [ -z "$KILO_KEY" ]; then
  if [ -t 0 ]; then
    read -r -p "Kilo Code API key (KILO_API_KEY, leave empty to skip): " KILO_KEY
  else
    KILO_KEY=""
  fi
fi
if [ -n "$KILO_KEY" ]; then
  umask 077
  {
    grep -v '^KILO_API_KEY=' "$HOME/.config/opencode/opencode.env" 2>/dev/null || true
    echo "KILO_API_KEY=$KILO_KEY"
  } > "$HOME/.config/opencode/opencode.env"
  chmod 600 "$HOME/.config/opencode/opencode.env"
  echo "KILO_API_KEY written to ~/.config/opencode/opencode.env (600)"
fi

# opencode daemon as a systemd service (keeps the proxy env + API key)
if [ -x "$HOME/.opencode/bin/opencode" ]; then
  cp "$REPO_DIR/systemd/opencode.service" "$HOME/.config/systemd/user/"
  systemctl --user daemon-reload
  "$HOME/.opencode/bin/opencode" service stop >/dev/null 2>&1 || true
  systemctl --user enable --now opencode.service
  sleep 4
  systemctl --user is-active opencode.service
else
  warn "opencode CLI not found at ~/.opencode/bin/opencode - skipping the daemon service"
fi

# ── 7. shell aliases ────────────────────────────────────────────────────────
log "shell aliases"
BASHRC="$HOME/.bashrc"
if ! grep -q "alias opencode=" "$BASHRC"; then
  cat >> "$BASHRC" <<'EOF'

# opencode / claude through the local gluetun (Proton) proxy
alias opencode='HTTPS_PROXY=http://127.0.0.1:8888 HTTP_PROXY=http://127.0.0.1:8888 NO_PROXY=localhost,127.0.0.1,::1 opencode'
alias claude='HTTPS_PROXY=http://127.0.0.1:8888 HTTP_PROXY=http://127.0.0.1:8888 NO_PROXY=localhost,127.0.0.1,::1 claude'
EOF
  echo "aliases added to .bashrc"
fi

log "done - verify with: bash scripts/verify.sh"
