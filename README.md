# Proton VPN exit gateway

Proton VPN (free tier) se ek **loopback-only** exit IP, aur usi se Claude Code
proxy + OpenCode + Claude Code CLI ka traffic.

```
   opencode CLI ─┐
   claude CLI   ─┤─> 127.0.0.1:4013 (claude-code-proxy) ─┐
                  │                                       ├─> 127.0.0.1:8888 (gluetun)
   opencode CLI ─┴────────────────────────────────────────┘         │
                          (Bun transport, ZEN identity)             ▼
                                                            Proton WireGuard (NL/US/JP/...)
                                                                    │
                                                          opencode.ai / ZEN
```

- **Loopback only** — proxy sirf `127.0.0.1:8888` pe publish hota hai, kabhi
  public pe nahi ( warna VM open proxy ban jata hai).
- **Auto exit-IP rotation** — 429 aaye to agla free-tier country (NL, US, JP,
  SG, PL, RO, NO, CA, MX) pick karke naya exit IP.
- **Zero-downtime proxy** — claude-code-proxy systemd user service hai, crash
  pe khud restart hota hai, bind conflict pe retry karta hai.

## New VM pe setup (one shot)

```bash
git clone https://github.com/arvindg4u/proton-vpn-gateway.git
cd proton-vpn-gateway
sudo bash scripts/setup-new-vm.sh --key "<Proton PrivateKey>"
bash scripts/verify.sh
```

`--key` nahi doge to script poochaega. Proton key kahan se: Proton account →
Downloads → WireGuard configuration → `PrivateKey = ...` (ek key saare free-tier
servers of same region pe chalti hai).

Setup script ye karta hai: docker + compose install → gluetun container (key
ke saath, health wait karke) → Bun runtime → `tor-proxy-toolkit` clone + venv +
`.env` (minimax models, naya session id, proxy env) → systemd units (dono
enable + linger) → OpenCode `zenproxy` provider → `.bashrc` aliases.

## Repo layout

| path | kya hai |
|---|---|
| `gluetun/docker-compose.yml` | Proton/gluetun container (loopback HTTP proxy) |
| `gluetun/.env.example` | `WIREGUARD_PRIVATE_KEY` + exit country |
| `gluetun/rotate_on_429.py` | 429 pe free-tier country switch → naya exit IP |
| `systemd/claude-code-proxy.service` | proxy ko systemd user service banata hai |
| `systemd/proton-rotate.service` | rotation daemon (auto-restart) |
| `opencode/opencode.json` | OpenCode ka `zenproxy` provider (local proxy route) |
| `scripts/setup-new-vm.sh` | new VM ka one-shot installer |
| `scripts/verify.sh` | poora chain ka health check |
| `docs/FINDINGS.md` | ZEN gate + network ka reverse-engineering notes |

Dependencies: [tor-proxy-toolkit](https://github.com/arvindg4u/tor-proxy-toolkit)
(mein claude-code-proxy hai — Bun transport + OpenCode identity usme hai).

## Daily use

```bash
# exit IP check
curl -x http://127.0.0.1:8888 https://ifconfig.me

# OpenCode: local proxy route (ZEN free quota khatam ho to bhi chalta hai)
opencode run -m zenproxy/sonnet "hello"
opencode                      # default model zenproxy/sonnet

# Claude Code (ANTHROPIC_BASE_URL=http://127.0.0.1:4013 already set)
claude -p "hello"

# services
systemctl --user status claude-code-proxy.service proton-rotate.service
```

## Troubleshooting

| symptom | cause | fix |
|---|---|---|
| `403 FreeTierError` from ZEN | request CLI jaisi nahi dikh rahi | Bun transport + identity headers chahiye (tor-proxy-toolkit) |
| `429 FreeUsageLimitError` | ZEN ka **daily** free-message quota khatam | 5:30 AM tak wait; naya exit IP se nahi khulega (key-scoped) |
| `Request timed out` + retries | model 15-20s tak koi byte nahi bhejta, gateway idle connection band kar deta hai | chhota/reasoning-off model, ya nayi session |
| `ECONNRESET` mid-stream | VPN restart ho raha tha (DoT reset) | `DNS_UPSTREAM_RESOLVER_TYPE=plain` compose me hai, verify karo |
| `ECONNREFUSED` on 4013 | proxy mar gaya | `systemctl --user restart claude-code-proxy.service` |
| `502` from nginx | proxy restart gap (10s) | `RestartSec=2` + bind retry (dono aa chuke hain) |
| opencode "API error" | model ka context limit cross ho gaya (deepseek = 200k) | `zenproxy/sonnet` (minimax, 1M context) use karo |

Details: [`docs/FINDINGS.md`](docs/FINDINGS.md).

## Security notes

- gluetun ka HTTP proxy **sirf** `127.0.0.1:8888` pe published hai.
- `.env` me secrets hain — repo me sirf `.env.example` hai, `.env` gitignored.
- proxy ke dashboard ka public URL (nginx + Let's Encrypt) alag hota hai aur
  `PUBLIC_BASE_URL` se decide hota hai.
