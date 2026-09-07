#!/usr/bin/env python3
"""Query Claude Code usage limits and emit a stable JSON document.

Standalone by design: the fragile part of this project is scraping the
human-readable output of `claude -p /usage`, so it lives here where it can be
run, diffed and tested without launching the GUI.

    ./claude_usage.py            # JSON to stdout
    ./claude_usage.py --raw      # the underlying text, for eyeballing changes
    ./claude_usage.py --fixture f.txt   # parse a saved capture instead of querying

Querying costs no tokens: /usage is handled client-side by Claude Code (it
returns num_turns=0 with an empty modelUsage), so polling this on a timer is
free.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

SCHEMA_VERSION = 1

# "Current session: 4% used · resets Sep 4 at 1:40pm (America/Denver)"
# "Current week (all models): 4% used · resets Sep 7 at 8am (America/Denver)"
# "Current week (Fable): 0% used"
# Deliberately generic in the label so a renamed or newly added model tier is
# still captured rather than dropped.
METRIC_RE = re.compile(
    r"^\s*Current\s+(?P<label>[^:]+?)\s*:\s*(?P<pct>\d+(?:\.\d+)?)\s*%\s*used"
    r"(?:\s*[·|,-]\s*resets\s+(?P<reset>[^\n]+?))?\s*$",
    re.MULTILINE | re.IGNORECASE,
)
ACTIVITY_RE = re.compile(
    r"Last\s+(?P<window>\d+)d\s*·\s*(?P<requests>\d+)\s+requests"
    r"(?:\s*·\s*(?P<sessions>\d+)\s+sessions)?",
    re.IGNORECASE,
)
# "Sep 4 at 1:40pm (America/Denver)" -> naive stamp + optional tz name
RESET_RE = re.compile(r"^(?P<stamp>.+?)\s*(?:\((?P<tz>[A-Za-z_]+/[A-Za-z_+-]+)\))?\s*$")
# Anchored to a leap year so "Feb 29" parses; the year is replaced below.
# (Bare year-less strptime is deprecated and becomes an error in 3.15.)
RESET_ANCHOR_YEAR = 2000
RESET_FORMATS = ("%b %d at %I:%M%p", "%b %d at %I%p", "%b %d at %H:%M")

# Metric keys the UI relies on; absence flips schema_ok and the app shows an
# explicit unknown state instead of a confident wrong number.
REQUIRED_KEYS = ("session", "week_all_models")


def slug(label: str) -> str:
    """'week (all models)' -> 'week_all_models'."""
    return re.sub(r"_+", "_", re.sub(r"[^a-z0-9]+", "_", label.strip().lower())).strip("_")


def parse_reset(text: str | None, now: datetime | None = None) -> dict[str, Any]:
    """Turn a reset phrase into an absolute time plus a countdown.

    /usage omits the year, so infer it: resets are always ahead of now, and a
    date that lands in the past means the window rolls into next year.
    """
    out: dict[str, Any] = {"raw": text, "at": None, "seconds_until": None, "timezone": None}
    if not text:
        return out
    m = RESET_RE.match(text.strip())
    if not m:
        return out
    tzname = m.group("tz")
    out["timezone"] = tzname
    tz = None
    if tzname:
        try:
            tz = ZoneInfo(tzname)
        except (ZoneInfoNotFoundError, ValueError):
            tz = None
    ref = (now or datetime.now(tz)) if tz else (now or datetime.now())
    if ref.tzinfo is None and tz is not None:
        ref = ref.replace(tzinfo=tz)
    stamp = m.group("stamp").strip()
    for fmt in RESET_FORMATS:
        try:
            naive = datetime.strptime(f"{RESET_ANCHOR_YEAR} {stamp}", f"%Y {fmt}")
        except ValueError:
            continue
        try:
            when = naive.replace(year=ref.year, tzinfo=tz)
            if when < ref - timedelta(days=1):  # window wrapped past new year
                when = when.replace(year=ref.year + 1)
        except ValueError:  # Feb 29 in a non-leap year
            out["at"] = None
            out["seconds_until"] = None
            break
        out["at"] = when.isoformat()
        out["seconds_until"] = max(0, int((when - ref).total_seconds()))
        break
    return out


def parse_usage(text: str, now: datetime | None = None) -> dict[str, Any]:
    """Parse /usage output into the JSON contract consumed by the Swift app."""
    metrics: dict[str, Any] = {}
    for m in METRIC_RE.finditer(text):
        used = float(m.group("pct"))
        key = slug(m.group("label"))
        metrics[key] = {
            "key": key,
            "label": m.group("label").strip(),
            "used_pct": used,
            "remaining_pct": round(100.0 - used, 2),
            "reset": parse_reset(m.group("reset"), now=now),
        }

    activity: dict[str, Any] = {}
    if a := ACTIVITY_RE.search(text):
        activity = {
            "window_days": int(a.group("window")),
            "requests": int(a.group("requests")),
            "sessions": int(a.group("sessions")) if a.group("sessions") else None,
            "local_only": True,  # /usage: "based on local sessions on this machine"
        }

    missing = [k for k in REQUIRED_KEYS if k not in metrics]
    return {
        "schema_version": SCHEMA_VERSION,
        "schema_ok": not missing,
        "missing_keys": missing,
        "metrics": metrics,
        "activity": activity,
    }


def query(claude_bin: str, timeout: float) -> str:
    """Run the free, client-side /usage command and return its result text.

    Uses --output-format json and reads .result: the envelope is a stable
    wrapper around volatile text, so warnings or extra chatter on stdout
    cannot corrupt the parse.
    """
    proc = subprocess.run(
        [claude_bin, "--safe-mode", "-p", "/usage", "--output-format", "json"],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"{claude_bin} exited {proc.returncode}: "
            f"{(proc.stderr or proc.stdout or '').strip()[:400]}"
        )
    try:
        envelope = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"could not decode --output-format json: {exc}") from exc
    if envelope.get("is_error"):
        raise RuntimeError(f"claude reported an error: {str(envelope.get('result'))[:400]}")
    result = envelope.get("result")
    if not isinstance(result, str) or not result.strip():
        raise RuntimeError("envelope had no .result text")
    return result


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Emit Claude Code usage limits as JSON.")
    ap.add_argument("--claude-bin", default="claude", help="claude executable (default: claude)")
    ap.add_argument("--timeout", type=float, default=30.0, help="seconds to wait (default: 30)")
    ap.add_argument("--raw", action="store_true", help="print the raw /usage text and exit")
    ap.add_argument("--fixture", help="parse this file instead of querying claude")
    ap.add_argument("--indent", type=int, default=None, help="pretty-print with this indent")
    args = ap.parse_args(argv)

    try:
        text = (
            open(args.fixture, encoding="utf-8").read()
            if args.fixture
            else query(args.claude_bin, args.timeout)
        )
    except FileNotFoundError:
        doc = {"ok": False, "error": f"claude executable not found: {args.claude_bin}",
               "schema_version": SCHEMA_VERSION, "schema_ok": False}
    except subprocess.TimeoutExpired:
        doc = {"ok": False, "error": f"timed out after {args.timeout}s",
               "schema_version": SCHEMA_VERSION, "schema_ok": False}
    except (RuntimeError, OSError) as exc:
        doc = {"ok": False, "error": str(exc),
               "schema_version": SCHEMA_VERSION, "schema_ok": False}
    else:
        if args.raw:
            print(text)
            return 0
        doc = {"ok": True, "error": None, **parse_usage(text)}
        doc["raw"] = text

    doc["queried_at"] = datetime.now().astimezone().isoformat()
    print(json.dumps(doc, indent=args.indent))
    # Exit 0 even on failure: the JSON carries the error so the app can render a
    # degraded state. Reserve nonzero for "no JSON produced at all".
    return 0


if __name__ == "__main__":
    sys.exit(main())
