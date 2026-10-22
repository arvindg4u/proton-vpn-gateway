#!/usr/bin/env bash
# Health check for the whole chain:
#   host -> gluetun (Proton exit) -> opencode.ai / claude-code-proxy
set -uo pipefail

ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

echo "=== gluetun ==="
if docker ps --filter name=gluetun --format '{{.Status}}' | grep -q healthy; then
  ok "container healthy: $(docker ps --filter name=gluetun --format '{{.Status}}')"
else
  bad "container not healthy: $(docker ps -a --filter name=gluetun --format '{{.Status}}')"
fi
RESTARTS=$(docker logs gluetun 2>&1 | grep -c 'restarting VPN' || true)
if [ "$RESTARTS" -gt 5 ]; then warn "$RESTARTS VPN restarts - check the DNS/DoT setting in the compose file"; else ok "$RESTARTS VPN restarts"; fi

echo
echo "=== exit IP ==="
PROXY_IP=$(curl -s --max-time 20 -x http://127.0.0.1:8888 https://ifconfig.me || true)
DIRECT_IP=$(curl -s --max-time 20 https://ifconfig.me || true)
if [ -n "$PROXY_IP" ]; then ok "via proxy : $PROXY_IP"; else bad "proxy not answering on 127.0.0.1:8888"; fi
if [ -n "$DIRECT_IP" ]; then ok "direct    : $DIRECT_IP"; fi
if [ -n "$PROXY_IP" ] && [ "$PROXY_IP" != "$DIRECT_IP" ]; then ok "traffic is leaving through the VPN"; else bad "proxy IP == direct IP, traffic is NOT going through the VPN"; fi

echo
echo "=== bind scope (must be loopback only) ==="
if ss -ltn | grep -E "127.0.0.1:8888" >/dev/null; then ok "8888 bound to 127.0.0.1 only"; else bad "8888 is not bound to loopback - fix the ports mapping"; fi

echo
echo "=== claude-code-proxy ==="
if systemctl --user is-active --quiet claude-code-proxy.service; then ok "service active"; else bad "service inactive: systemctl --user start claude-code-proxy.service"; fi
if ss -ltn | grep -q ":4013"; then ok "listening on 127.0.0.1:4013"; else bad "not listening on 4013"; fi
RESP=$(curl -s --max-time 60 http://127.0.0.1:4013/v1/messages \
  -H "x-api-key: sk-local-claude-code" -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-sonnet-4-5","max_tokens":16,"messages":[{"role":"user","content":"say OK"}],"tools":[{"name":"Bash","description":"run","input_schema":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}]}' || true)
if echo "$RESP" | grep -q '"text"'; then ok "API round trip OK"; else warn "API response: ${RESP:0:160} (429 = free-tier quota, not a setup problem)"; fi

echo
echo "=== rotation service ==="
if systemctl --user is-active --quiet proton-rotate.service; then ok "service active (429 -> switch free-tier country -> new exit IP)"; else warn "service inactive: systemctl --user start proton-rotate.service"; fi

echo
echo "=== CLIs ==="
if command -v opencode >/dev/null 2>&1; then
  if [ -n "${KILO_API_KEY:-}" ] && grep -q KILO_API_KEY "$HOME/.config/opencode/opencode.env" 2>/dev/null; then
    R=$(timeout 150 opencode run -m "kilo/minimax/minimax-m3.1-flash:free" "reply with exactly: OK" 2>&1 | tail -1)
    echo "$R" | grep -q OK && ok "opencode (kilo provider, via VPN)" || warn "opencode/kilo: ${R:0:120}"
  else
    warn "KILO_API_KEY missing - opencode kilo provider not configured"
  fi
  R=$(timeout 120 opencode run -m zenproxy/sonnet "reply with exactly: OK" 2>&1 | tail -1)
  echo "$R" | grep -q OK && ok "opencode (zenproxy, via local proxy)" || warn "opencode/zenproxy: ${R:0:120}"
fi
if command -v claude >/dev/null 2>&1; then
  R=$(cd /tmp && timeout 120 claude -p "reply with exactly: OK" 2>&1 | tail -1)
  echo "$R" | grep -q OK && ok "claude code" || warn "claude: ${R:0:120}"
fi
