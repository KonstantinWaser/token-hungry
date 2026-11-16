#!/usr/bin/env python3
# <xbar.title>Claude Usage</xbar.title>
# <xbar.desc>Claude plan limits (session, weekly) with reset countdowns.</xbar.desc>
# <xbar.author.github>alexander-posztos</xbar.author.github>
# <xbar.abouturl>https://github.com/alexander-posztos/token-hungry</xbar.abouturl>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>

# Reads Claude Code's login from the Keychain and asks the endpoint behind
# its /usage command. Banked resets only come back for Claude Code's user agent.

import contextlib
import io
import json
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import minecraft

URL = "https://api.anthropic.com/api/oauth/usage?cedar_ember=1"
CACHE = Path(__file__).resolve().parent / ".claude-usage.json"
VERSION = "2.1.323"  # Claude Code version to claim when the claude command is missing
COLORS = ((90, "#ef4444"), (75, "#f97316"), (50, "#eab308"), (0, "#22c55e"))
ICON = "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"


def countdown(secs):
    d, h, m = secs // 86400, secs % 86400 // 3600, secs % 3600 // 60
    return f"{d}d {h}h" if d else f"{h}h {m}m" if h else f"{m}m"


# Prints the menu from rows of (label, percent used, seconds until reset).
# A row without a running window has no seconds.
def render(rows):
    title = " · ".join(f"{label[0]} {pct}%" for label, pct, _ in rows)
    print(f"{title} | templateImage={ICON}")
    print("---")
    for label, pct, secs in rows:
        filled = min(10, round(pct / 10))
        bar = "█" * filled + "░" * (10 - filled)
        color = next(c for threshold, c in COLORS if pct >= threshold)
        reset = f"   resets in {countdown(secs)}" if secs else ""
        print(f"{label:<8}{bar} {pct:>3}%{reset} | font=Menlo size=13 color={color}")


# Prints the banked resets from (name, usable from, expires) as ISO dates,
# either of which can be missing. Resets of one kind share a line.
def render_resets(resets):
    groups = {}
    for name, start, end in resets:
        line = f"{name.title()} reset"
        if start and day(start) > datetime.now(timezone.utc):
            line += f" from {day(start).day} {day(start):%b}"
        groups.setdefault(line, []).append(f"{day(end).day} {day(end):%b}" if end else "")
    if groups:
        print("---")
    for line, ends in groups.items():
        until = " · ".join(dict.fromkeys(filter(None, ends)))
        if until:
            line += f" until {until}"
        print(f"{len(ends)}× {line} | font=Menlo size=13")


def day(iso):
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone()


# Claude Code's user agent with the installed version, since Anthropic stops
# returning banked resets to versions that have grown old.
def user_agent():
    try:
        version = subprocess.check_output(["claude", "--version"], text=True).split()[0]
    except Exception:
        version = VERSION
    return f"claude-cli/{version} (external, cli)"


# Claude Code keeps its login in the Keychain on macOS and in a file elsewhere.
def credentials():
    if sys.platform == "darwin":
        command = ["security", "find-generic-password", "-ws", "Claude Code-credentials"]
        return subprocess.check_output(command)
    return (Path.home() / ".claude" / ".credentials.json").read_text()


# The endpoint rate-limits each account, and Claude Code asks it too, so the
# last answer is kept and shown again while it says 429. Returns the usage and,
# for a kept answer, when it was fetched.
def fetch():
    token = json.loads(credentials())["claudeAiOauth"]["accessToken"]
    headers = {"Authorization": f"Bearer {token}", "User-Agent": user_agent()}
    request = urllib.request.Request(URL, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            usage = json.load(response)
    except urllib.error.HTTPError as error:
        if error.code != 429 or not CACHE.exists():
            raise
        return json.loads(CACHE.read_text()), datetime.fromtimestamp(CACHE.stat().st_mtime)
    CACHE.write_text(json.dumps(usage))
    return usage, None


def main():
    usage, kept = fetch()

    now = datetime.now(timezone.utc)
    rows = []
    for limit in usage["limits"]:
        kind, reset = limit["kind"], limit["resets_at"]
        label = {"session": "Session", "weekly_all": "Weekly"}.get(kind)
        if not label:  # ponytail: per-model limits left out; read limit["scope"]["model"] to bring them back
            continue
        secs = reset and int((day(reset) - now).total_seconds())
        rows.append((label, round(limit["percent"]), secs))
    render(rows)
    grants = (usage.get("cedar_ember") or {}).get("grants") or []
    render_resets((grant["type"], grant["starts_at"], grant["ends_at"])
                  for grant in grants for _ in range(grant["resets_left"]))
    print("---")
    if kept:
        print(f"Rate limited, as of {kept:%H:%M} | font=Menlo size=13 color=#9ca3af")
    print("Usage settings | href=https://claude.ai/settings/usage")
    print("Refresh | refresh=true")


# The menu is printed into a buffer, so minecraft.py can add its switches and
# redraw it in Minecraft mode.
with contextlib.redirect_stdout(io.StringIO()) as output:
    try:
        main()
    except Exception as error:
        print(f"⚠︎ | templateImage={ICON}")
        print("---")
        print(error)
        print("Refresh | refresh=true")
print(minecraft.menu("Claude", output.getvalue()), end="")
