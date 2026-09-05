#!/usr/bin/env python3
"""Build ClaudeUsage.app.

CommandLineTools has no usable `xcodebuild` for app targets, so this compiles
with SwiftPM and assembles the .app bundle by hand.

    ./build.py            # build into ./dist/Claude Usage.app
    ./build.py --install  # also copy into /Applications
    ./build.py --run      # relaunch it when done
"""

from __future__ import annotations

import argparse
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BINARY = "ClaudeUsageBar"
APP_NAME = "Claude Usage.app"
# Must match the domain documented for `defaults write` overrides in
# UsageFetcher.swift.
BUNDLE_ID = "com.claudeusagebar.app"
VERSION = "1.0"

INFO_PLIST = {
    "CFBundleName": "Claude Usage",
    "CFBundleDisplayName": "Claude Usage",
    "CFBundleExecutable": BINARY,
    "CFBundleIdentifier": BUNDLE_ID,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": VERSION,
    "CFBundleVersion": VERSION,
    "LSMinimumSystemVersion": "13.0",
    # Menu bar only: no dock icon, no app switcher entry.
    "LSUIElement": True,
    "NSHumanReadableCopyright": "",
}


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    print(f"  $ {' '.join(str(c) for c in cmd)}")
    return subprocess.run(cmd, check=True, cwd=ROOT, **kw)


def build_app(dest_dir: Path, sign: str) -> Path:
    print("compiling (release)")
    run(["swift", "build", "-c", "release"])
    binary_src = Path(
        subprocess.run(
            ["swift", "build", "-c", "release", "--show-bin-path"],
            check=True, capture_output=True, text=True, cwd=ROOT,
        ).stdout.strip()
    ) / BINARY
    if not binary_src.is_file():
        sys.exit(f"error: built binary not found at {binary_src}")

    app = dest_dir / APP_NAME
    if app.exists():
        shutil.rmtree(app)
    macos = app / "Contents" / "MacOS"
    resources = app / "Contents" / "Resources"
    macos.mkdir(parents=True)
    resources.mkdir(parents=True)

    print(f"assembling {app.name}")
    shutil.copy2(binary_src, macos / BINARY)
    (macos / BINARY).chmod(0o755)

    # The parser ships inside the bundle so the app is self-contained; it stays
    # a plain readable .py you can run standalone from Resources.
    parser_src = ROOT / "parser" / "claude_usage.py"
    shutil.copy2(parser_src, resources / "claude_usage.py")
    (resources / "claude_usage.py").chmod(0o755)

    with open(app / "Contents" / "Info.plist", "wb") as fh:
        plistlib.dump(INFO_PLIST, fh)

    # Ad-hoc (`-`, the default) is enough for a locally built app to launch
    # cleanly, but each ad-hoc sign is a new identity, so macOS resets TCC
    # grants on every rebuild; pass --sign with a persistent identity to
    # avoid that (see README).
    print(f"signing ({sign})")
    run(["codesign", "--force", "--sign", sign, str(app)])
    return app


def main() -> int:
    ap = argparse.ArgumentParser(description="Build the Claude Usage menu bar app.")
    ap.add_argument("--install", action="store_true", help="copy into /Applications")
    ap.add_argument("--run", action="store_true", help="relaunch the app after building")
    ap.add_argument("--dest", default="dist", help="output directory (default: dist)")
    ap.add_argument("--sign", default="-",
                     help="codesign identity (default: '-' ad-hoc)")
    args = ap.parse_args()

    dest_dir = (ROOT / args.dest).resolve()
    dest_dir.mkdir(parents=True, exist_ok=True)
    app = build_app(dest_dir, args.sign)

    if args.install:
        target = Path("/Applications") / APP_NAME
        print(f"installing to {target}")
        subprocess.run(["pkill", "-f", f"{BINARY}"], check=False)
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(app, target)
        app = target

    if args.run:
        print("relaunching")
        subprocess.run(["pkill", "-f", BINARY], check=False)
        subprocess.run(["open", str(app)], check=True)

    print(f"\ndone: {app}")
    if not args.run:
        print(f"launch with:  open '{app}'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
