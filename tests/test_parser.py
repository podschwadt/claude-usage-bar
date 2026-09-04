#!/usr/bin/env python3
"""Fixture tests for the /usage parser. Run: python3 tests/test_parser.py"""
import sys, pathlib
from datetime import datetime
from zoneinfo import ZoneInfo

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "parser"))
from claude_usage import parse_usage, parse_reset, slug  # noqa: E402

NOW = datetime(2026, 9, 4, 13, 23, tzinfo=ZoneInfo("America/Denver"))

LIVE = """You are currently using your subscription to power your Claude Code usage

Current session: 4% used · resets Sep 4 at 1:40pm (America/Denver)
Current week (all models): 4% used · resets Sep 7 at 8am (America/Denver)
Current week (Fable): 0% used

What's contributing to your limits usage?
Approximate, based on local sessions on this machine — does not include other devices or claude.ai.

Last 7d · 55 requests · 7 sessions
  73% of your usage was at >150k context
"""

# A future rename of the tier lines: must NOT silently report 100% remaining.
RENAMED = """You are currently using your subscription to power your Claude Code usage

Usage this session: 40% of limit
Weekly total: 12% of limit
"""

# Fable tier absent entirely (e.g. plan without it) - schema still valid.
NO_FABLE = """Current session: 88% used · resets Sep 4 at 1:40pm (America/Denver)
Current week (all models): 91% used · resets Sep 7 at 8am (America/Denver)
"""

FRACTIONAL = "Current session: 99.5% used\nCurrent week (all models): 0% used\n"

failures = []

def check(name, cond, detail=""):
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name} {detail}")
        failures.append(name)

print("slug normalisation")
check("week (all models)", slug("week (all models)") == "week_all_models")
check("week (Fable)", slug("week (Fable)") == "week_fable")

print("live format")
d = parse_usage(LIVE, now=NOW)
check("schema_ok", d["schema_ok"])
check("session remaining 96", d["metrics"]["session"]["remaining_pct"] == 96.0)
check("fable remaining 100", d["metrics"]["week_fable"]["remaining_pct"] == 100.0)
check("requests 55", d["activity"]["requests"] == 55)
check("activity flagged local", d["activity"]["local_only"] is True)
s = d["metrics"]["session"]["reset"]["seconds_until"]
check("session resets in ~17min", s is not None and 900 < s < 1100, f"got {s}")

print("renamed tiers (the dangerous case)")
d = parse_usage(RENAMED, now=NOW)
check("schema_ok is False", d["schema_ok"] is False)
check("missing keys reported", set(d["missing_keys"]) == {"session", "week_all_models"})
check("no invented metrics", d["metrics"] == {})

print("fable tier absent")
d = parse_usage(NO_FABLE, now=NOW)
check("schema_ok", d["schema_ok"])
check("no fable key", "week_fable" not in d["metrics"])
check("session remaining 12", d["metrics"]["session"]["remaining_pct"] == 12.0)

print("fractional percent")
d = parse_usage(FRACTIONAL, now=NOW)
check("99.5 -> 0.5 remaining", d["metrics"]["session"]["remaining_pct"] == 0.5)

print("reset edge cases")
check("no reset text", parse_reset(None)["at"] is None)
check("unparseable kept raw", parse_reset("in a little while")["raw"] == "in a little while")
check("unparseable has no time", parse_reset("in a little while")["at"] is None)
# Year wrap: a Jan reset seen from December must land next year.
dec = datetime(2026, 12, 31, 23, 0, tzinfo=ZoneInfo("America/Denver"))
w = parse_reset("Jan 2 at 8am (America/Denver)", now=dec)
check("year wraps to 2027", w["at"].startswith("2027-01-02"), f"got {w['at']}")
check("leap day survives", parse_reset("Feb 29 at 8am (America/Denver)", now=NOW) is not None)

print()
if failures:
    print(f"{len(failures)} FAILED: {', '.join(failures)}")
    sys.exit(1)
print("all tests passed")
