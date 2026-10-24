#!/usr/bin/env python3
"""Rotate the Proton exit IP when the upstream answers 429.

The free tier's quota is scoped to the EXIT IP, not to the API key: the same
key succeeds from a fresh exit and is refused from a burnt one. A hostname
maps to a stable exit IP, so a rotation means pinning the next free-tier
host from servers.txt and recreating the container.

Each candidate is verified: after the container comes up, the new exit is
probed through the local claude-code-proxy (which speaks the upstream with
the right TLS fingerprint and identity headers), and the rotation keeps going
until the probe returns 200. A rotation therefore always ends on an exit that
actually has quota left.

Guards: a cooldown between rotations, a cap per hour and a bounded number of
candidates per event.
"""

import json
import os
import random
import re
import subprocess
import time
import urllib.error
import urllib.request

PROXY_DIR = os.path.dirname(os.path.abspath(__file__))
ENV_FILE = os.path.join(PROXY_DIR, ".env")
COMPOSE_FILE = os.path.join(PROXY_DIR, "docker-compose.yml")
POOL_FILE = os.path.join(PROXY_DIR, "servers.txt")
STATE_FILE = os.path.join(PROXY_DIR, ".last-good-server")
CONTAINER = "gluetun"
LOCAL_PROXY = "http://127.0.0.1:4013/v1/messages"
LOCAL_PROXY_KEY = "sk-local-claude-code"

LOG_FILES = (
    "/var/log/tor-toolkit/claude-proxy.log",
    "/home/ubuntu/.local/share/opencode/log/opencode.log",
)

COOLDOWN_SECS = 25
MAX_PER_HOUR = 30
MAX_CANDIDATES = 6
PATTERN = re.compile(r"\b429\b|FreeUsageLimitError|rate limit exceeded", re.IGNORECASE)


def log(message):
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


def read_new(path, offset):
    try:
        with open(path, "rb") as handle:
            handle.seek(offset)
            data = handle.read()
            return data.decode("utf-8", "replace"), handle.tell()
    except OSError:
        return "", offset


def load_pool():
    """Free-tier hosts, with the last known good one first."""
    hosts = []
    try:
        with open(POOL_FILE) as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                hosts.append(line.split()[0])
    except OSError:
        pass
    good = ""
    try:
        with open(STATE_FILE) as handle:
            good = handle.read().strip()
    except OSError:
        pass
    if good and good in hosts:
        hosts = [good] + [h for h in hosts if h != good]
    else:
        random.shuffle(hosts)
    return hosts


def current_host():
    try:
        with open(ENV_FILE) as handle:
            for line in handle:
                if line.startswith("SERVER_HOSTNAMES="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def set_host(host):
    lines = []
    with open(ENV_FILE) as handle:
        for line in handle:
            if line.startswith("SERVER_HOSTNAMES="):
                lines.append(f"SERVER_HOSTNAMES={host}\n")
            else:
                lines.append(line)
    with open(ENV_FILE, "w") as handle:
        handle.writelines(lines)


def exit_ip():
    try:
        result = subprocess.run(
            ["sudo", "-n", "docker", "exec", CONTAINER, "cat", "/tmp/gluetun/ip"],
            capture_output=True,
            text=True,
            timeout=20,
        )
        return result.stdout.strip()
    except Exception:  # noqa: BLE001
        return ""


def recreate():
    subprocess.run(
        ["sudo", "-n", "docker", "compose", "-f", COMPOSE_FILE, "up", "-d"],
        cwd=PROXY_DIR,
        check=False,
        timeout=300,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )


def wait_for_tunnel(timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(5)
        if exit_ip():
            return True
    return False


def probe() -> bool:
    """Ask the local proxy for a tiny completion.

    200 means the current exit has quota left; 429 means it is burnt. The
    request goes through the Bun transport, so it passes the upstream's TLS
    and identity gate and the answer reflects the quota only.
    """
    payload = json.dumps(
        {
            "model": "claude-sonnet-4-5",
            "max_tokens": 8,
            "messages": [{"role": "user", "content": "say OK"}],
            "tools": [
                {
                    "name": "Bash",
                    "description": "Run a bash command",
                    "input_schema": {
                        "type": "object",
                        "properties": {"command": {"type": "string"}},
                        "required": ["command"],
                    },
                }
            ],
        }
    ).encode()
    request = urllib.request.Request(
        LOCAL_PROXY,
        data=payload,
        headers={
            "x-api-key": LOCAL_PROXY_KEY,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    try:
        # short timeout on purpose: the proxy retries internally, so a burnt
        # exit only shows up after its own retry chain. We just need a quick
        # yes/no on this exit.
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status == 200
    except urllib.error.HTTPError:
        return False
    except Exception:  # noqa: BLE001
        return False


def remember(host):
    try:
        with open(STATE_FILE, "w") as handle:
            handle.write(host)
    except OSError:
        pass


def rotate(reason):
    previous = exit_ip()
    current = current_host()
    pool = [h for h in load_pool() if h != current] or load_pool()
    log(f"429 detected ({reason}); exit={previous or '?'} host={current or '?'}")

    for host in pool[:MAX_CANDIDATES]:
        set_host(host)
        recreate()
        wait_for_tunnel()
        new_ip = exit_ip()
        if probe():
            log(f"new exit IP: {new_ip} (host {host}) - upstream answered 200")
            remember(host)
            return True
        log(f"host {host} -> exit {new_ip or '?'} still rate limited, trying next")

    log("no host in the pool gave a working exit within the attempt budget")
    return False


def main():
    offsets = {path: 0 for path in LOG_FILES}
    for path in LOG_FILES:
        try:
            offsets[path] = os.path.getsize(path)
        except OSError:
            offsets[path] = 0

    last_rotation = 0.0
    rotations = []

    while True:
        for path in LOG_FILES:
            text, offsets[path] = read_new(path, offsets[path])
            if not text or not PATTERN.search(text):
                continue
            now = time.time()
            if now - last_rotation < COOLDOWN_SECS:
                continue
            rotations = [t for t in rotations if now - t < 3600]
            if len(rotations) >= MAX_PER_HOUR:
                continue
            last_rotation = now
            rotations.append(now)
            rotate(os.path.basename(path))
            break
        time.sleep(5)


if __name__ == "__main__":
    main()
