#!/usr/bin/env python3
"""Rotate the Proton exit IP by switching to another free-tier country.

The OpenCode ZEN free tier rate limits per exit IP, so a fresh exit clears
the window. A plain `docker restart gluetun` is not enough: gluetun always
re-picks the same "best" server, so the exit IP stays the same. This
therefore switches SERVER_COUNTRIES in .env to another free-tier country
(Netherlands, United States, Japan, Singapore, Poland, Romania, Norway,
Canada, Mexico), recreates the container and waits for the new exit IP.

Guards: a cooldown between rotations, a cap per hour, and a check that the
exit IP actually changed, so a stuck 429 cannot turn into a restart loop.
"""

import os
import random
import re
import subprocess
import time

PROXY_DIR = "/home/ubuntu/proton-proxy"
ENV_FILE = os.path.join(PROXY_DIR, ".env")
COMPOSE_FILE = os.path.join(PROXY_DIR, "docker-compose.yml")
CONTAINER = "gluetun"

# Free tier countries (verified with FREE_ONLY=on) and a sample exit IP.
FREE_COUNTRIES = (
    "Netherlands",
    "United States",
    "Japan",
    "Singapore",
    "Poland",
    "Romania",
    "Norway",
    "Canada",
    "Mexico",
)

LOG_FILES = (
    "/var/log/tor-toolkit/claude-proxy.log",
    "/home/ubuntu/.local/share/opencode/log/opencode.log",
)

COOLDOWN_SECS = 1800
MAX_PER_HOUR = 6
# If a 429 still shows up right after a rotation, the limit is not
# IP-scoped (it is key-scoped on ZEN's side), so rotating again only
# bounces the tunnel and kills in-flight streams. Pause instead.
FAILED_ROTATION_WINDOW = 1800
QUIET_PERIOD = 7200
PATTERN = re.compile(r"\b429\b|FreeUsageLimitError|rate limit exceeded", re.IGNORECASE)


def log(message):
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


def read_new(path, offset):
    """Return (new_text, new_offset) for everything appended since offset."""
    try:
        with open(path, "rb") as handle:
            handle.seek(offset)
            data = handle.read()
            return data.decode("utf-8", "replace"), handle.tell()
    except OSError:
        return "", offset


def current_country():
    try:
        with open(ENV_FILE) as handle:
            for line in handle:
                if line.startswith("SERVER_COUNTRIES="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def set_country(country):
    lines = []
    replaced = False
    with open(ENV_FILE) as handle:
        for line in handle:
            if line.startswith("SERVER_COUNTRIES="):
                lines.append(f"SERVER_COUNTRIES={country}\n")
                replaced = True
            else:
                lines.append(line)
    if not replaced:
        lines.append(f"SERVER_COUNTRIES={country}\n")
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


def rotate(reason):
    previous = exit_ip()
    current = current_country()
    candidates = [c for c in FREE_COUNTRIES if c != current] or list(FREE_COUNTRIES)
    country = random.choice(candidates)
    log(f"429 detected ({reason}); exit={previous or '?'} country={current or '?'} -> {country}")
    set_country(country)
    recreate()

    deadline = time.time() + 150
    new_ip = ""
    while time.time() < deadline:
        time.sleep(8)
        new_ip = exit_ip()
        if new_ip and new_ip != previous:
            break
    if new_ip and new_ip != previous:
        log(f"new exit IP: {new_ip} (country {country})")
        return True
    log(f"exit IP did not change (still {new_ip or '?'})")
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
    quiet_until = 0.0

    while True:
        for path in LOG_FILES:
            text, offsets[path] = read_new(path, offsets[path])
            if not text or not PATTERN.search(text):
                continue
            now = time.time()
            if now < quiet_until:
                continue
            if last_rotation and now - last_rotation < FAILED_ROTATION_WINDOW:
                quiet_until = now + QUIET_PERIOD
                log(
                    "429 again right after a rotation -> limit is not IP-scoped; "
                    f"pausing rotations for {QUIET_PERIOD // 60} min"
                )
                last_rotation = 0.0
                break
            if now - last_rotation < COOLDOWN_SECS:
                continue
            rotations = [t for t in rotations if now - t < 3600]
            if len(rotations) >= MAX_PER_HOUR:
                continue
            last_rotation = now
            rotations.append(now)
            rotate(os.path.basename(path))
            break
        time.sleep(10)


if __name__ == "__main__":
    main()
