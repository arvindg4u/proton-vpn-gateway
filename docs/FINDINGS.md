# Findings: OpenCode ZEN free-tier gate + Proton exit networking

Sab kuch live verify kiya gaya hai (Oct 2026), `opencode.ai/zen` ke against.

## 1. ZEN free tier ka gate (403 FreeTierError)

Request "OpenCode CLI se aayi hai" ye prove karna hai. Teen checks:

### a) TLS ClientHello fingerprint
Ye sabse bada pakka hua finding hai. **Byte-for-byte same request**:

| client | result |
|---|---|
| curl / Python httpx (OpenSSL) | `403 FreeTierError` |
| Bun (BoringSSL — wahi jo real CLI use karta hai) | `200 OK` |

Gate TLS handshake fingerprint karta hai. Isliye upstream call httpx se nahi,
**Bun se** karni padti hai (tor-proxy-toolkit: `claude-code-proxy/bun/zen_fetch.ts`
+ `src/core/bun_transport.py`).

### b) OpenCode identity headers
Real CLI ke captured headers (MITM se):

```
POST https://opencode.ai/inference/openai/v1/chat/completions
Authorization: Bearer public
User-Agent: opencode/latest/2.1.2/cli
Content-Type: application/json
x-opencode-client: cli
x-opencode-project: <40 lowercase hex>
x-opencode-session: ses_<12 hex><14 alnum>
x-opencode-session-id: ses_...
x-session-affinity: ses_...
x-session-id: ses_...
b3: <traceid>-<spanid>-1-<traceid>
traceparent: 00-<traceid>-<spanid>-01
```

- `x-opencode-*` family hatao → 403.
- `x-opencode-project` 40 hex char ka hona chahiye.
- `x-opencode-session` ka format strict hai: `ses_` + 12 lowercase hex + 14
  alphanumerics. Galat id → 403 (isliye config `_coerce_session_id` invalid id
  ko reject karke fresh valid id banata hai).
- User-Agent ka exact version matter nahi karta (dono `opencode/1.19.3` aur
  `opencode/latest/2.1.2/cli` pass hue), format matter karta hai.
- API key: `oc_sk_...` bhi chalta hai, `Bearer public` bhi.

### c) Body shape
- Body me **kam se kam ek tool definition** chahiye, warna 403.
- "Partial/foreign" tool set bhi reject hota hai — poora genuine 27-tool
  manifest (captured verbatim) + caller ke tools uske baad chahiye
  (`src/core/cli_identity.py:GENUINE_CLI_TOOLS`).
- `stream: true` bhi chahiye (non-streaming reject).
- SDK fingerprint headers (`x-stainless-*`, `openai-*`) hatao, `accept: */*`
  bhejo (CLI aisa karta hai).

### d) Path
`/zen/v1/chat/completions` aur `/inference/openai/v1/chat/completions` dono
 chale (gate path nahi check karta).

## 2. 429 FreeUsageLimitError

- Ye **daily quota** hai: *"You've used today's free messages. They reset at
  5:30 AM"*. Key-scoped hai — **exit IP badalne se nahi khulta** (Netherlands →
  Singapore rotate karke bhi same 429 aaya).
- Isliye rotation sirf IP-scoped limits ke liye; daily quota ke liye wait karna
  padta hai.
- claude-code-proxy ka local rate guard 429 pe requests hold karta hai
  (10→20→40→60s) taaki quota zyada na kharch ho.

## 3. Idle connection ~20s me band (timeout ka asli reason)

`opencode.ai` ka gateway idle HTTP/1.1 connection ~15-20s baad close kar deta
hai. Ye **server side** hai, VPN se related nahi:

| test | result |
|---|---|
| direct, normal IP | 20s pe EOF |
| direct, pinned IP | 20s pe EOF |
| via proxy | 20s pe EOF |

Matlab: model 15-20s tak koi byte nahi bhejta (reasoning/thinking phase) →
connection kat jata hai → CLI "Request timed out" → retry → same bada request
dobara → phir same timeout.

Practical: chhota context ya non-reasoning model, ya nayi session.

## 4. Model context limits (opencode catalog se)

| model | context |
|---|---|
| `opencode/deepseek-v4.1-flash-free` | 200,000 |
| `opencode/glm-5.3-flash-free` | 200,000 |
| `opencode/minimax-m3.1-flash-free` | 1,000,000 |
| `opencode/muse-spark-1.3` | 1,048,576 |

200k se upar ka session har request pe fail hota hai (API error + retry loop).

## 5. Proton/gluetun networking

- **DoT (port 853) reset hota hai** — Proton ke servers `cloudflare-dns.com`
  ke DoT handshake ko reset karte hain. Gluetun ka DNS phir resolve hi nahi
  karta → healthcheck fail → VPN restart loop (906 restarts, 2049 failed
  healthchecks, tunnel dead). Fix:
  `DNS_UPSTREAM_RESOLVER_TYPE=plain` + `DNS_UPSTREAM_PLAIN_ADDRESSES=1.1.1.1:53,8.8.8.8:53`.
- **ICMP echo drop/throttle hota hai** → per-minute healthcheck fail → fix:
  `HEALTH_SMALL_CHECK_TYPE=dns`.
- **MTU**: gluetun 1400 default use karta hai; Proton path par oversized
  segments drop hote the → TLS handshake 546ms (retransmit). `WIREGUARD_MTU=1280`
  se ~290ms.
- **Exit IP rotate karna**: gluetun har restart pe wahi "best" server pick
  karta hai → same exit IP. Country badalna padta hai (`.env:SERVER_COUNTRIES`).
  Free-tier countries: Netherlands, United States, Japan, Singapore, Poland,
  Romania, Norway, Canada, Mexico.
- **Cloudflare edge IP**: `opencode.ai` ke apne A records (172.65.90.x) se
  Oracle Mumbai ka path kharab hai (TLS handshake 420-440ms vs 13-23ms dusre
  Cloudflare IPs pe). Pinning se direct path ~250ms ho jata hai, par ye
  fragile hai (third-party anycast IP pin) — default rakha gaya hai.

## 6. opencode CLI ka traffic kaise prove karte hain

```bash
# 1. webfetch tool se andar se exit IP
opencode run -m minimax-m3.1-flash-free \
  "use webfetch to fetch https://ifconfig.me and give the IP"

# 2. process level
tr '\0' '\n' < /proc/$(pgrep -f "opencode serve --service")/environ | grep PROXY

# 3. live call me daemon ka proxy connection
ss -tnp | grep 127.0.0.1:8888
```

Model calls daemon se nikalte hain (`opencode serve --service`), CLI process
se nahi — isliye proxy env daemon me hona zaroori hai.

## 7. systemd user service ke do gotchas

1. **Docker socket access**: user manager ko `docker` group nahi milta agar
   manager group add hone se pehle start hua tha → `SupplementaryGroups=docker`
   se `status=216/GROUP` fail hota hai. Fix: `sudo -n docker ...` use karo.
2. **Restart gap**: `RestartSec=10` → nginx 502 deta hai; `RestartSec=2` +
   app-level bind retry (EADDRINUSE pe 10× retry) se gap khatam.
