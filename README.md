# Claude Usage — macOS menu bar

A compact menu bar readout of remaining Claude Code limits, in the style of
iStat-type system monitors:

```
S 95%      <- tightest of session / weekly limits, remaining
F 100%     <- Fable weekly, remaining
```

Polling is **free**: `claude --safe-mode -p "/usage"` is handled entirely
client-side. Measured with `--output-format json`, it reports `num_turns: 0`,
`duration_api_ms: 0`, an empty `modelUsage` and `total_cost_usd: 0` while still
returning the usage text. 22 consecutive calls did not move the session
percentage. (A near-identical prompt *without* the leading slash — e.g.
`\usage` — is an ordinary prompt and does cost ~$0.04, mostly system-prompt
cache.)

## Architecture

    parser/claude_usage.py   scrapes `claude -p /usage` -> JSON      (no deps, py3.9+)
    Sources/ClaudeUsageBar/  AppKit NSStatusItem, polls the parser   (Swift 5.9+)

The parser is deliberately separate and standalone: text-scraping an
undocumented command is the fragile part, so it can be run, diffed and tested
without launching the GUI.

```sh
parser/claude_usage.py --indent 2      # the JSON contract
parser/claude_usage.py --raw           # underlying text, to eyeball changes
parser/claude_usage.py --fixture f.txt # parse a saved capture
python3 tests/test_parser.py           # 20 fixture tests
```

### Guarding against silent wrongness

A scraper that quietly reports the wrong number is worse than one that fails.
The parser matches tier lines generically (`Current <label>: N% used`) so a new
or renamed model tier is still captured, and sets `schema_ok: false` with
`missing_keys` if the lines it depends on disappear. The app then shows an
orange `?` rather than a stale or invented percentage.

Note `activity` carries `local_only: true` — `/usage` states the request and
session counts cover local sessions on this machine only. The percentages
themselves are server-side.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools — `xcode-select --install`
- Claude Code, installed and signed in

No Python install is needed: `/usr/bin/python3` is a shim that requires the
Command Line Tools, and those are already required to compile the Swift, so
building the app implies a working interpreter. Nothing from Homebrew is used.

Tested against a subscription plan. API-key users may see different `/usage`
output, in which case the app shows `?` and `schema_ok` reports what was missed.

## Build

```sh
git clone <repo> && cd claude-usage-bar
./build.py --install --run   # -> /Applications, and launch
```

Or `./build.py` alone to leave it in `dist/`.

Full Xcode is *not* needed: SwiftPM compiles the binary and `build.py`
assembles the `.app` by hand, ad-hoc signed. The parser is copied into
`Contents/Resources`, so **rebuild after editing `parser/claude_usage.py`**.

Building locally is also what keeps distribution simple — the app picks up the
host architecture, and a locally built bundle carries no quarantine flag, so
there is no Gatekeeper prompt and no Developer ID or notarisation involved.
Shipping a prebuilt binary would need all three (plus `lipo`-ing separate
arm64/x86_64 slices, since SwiftPM's `--arch` needs full Xcode).

## Menu

Full breakdown with reset countdowns, 7-day local activity, and:

- **Menu bar shows** — tightest limit (default), Session, Week, or Fable only
- **Refresh every** — 30s / 1m / 5m / 15m (default 1m)
- Refresh Now (⌘R), Copy /usage Output (⌘C), Open at Login, Quit (⌘Q)

Colour is used sparingly, the native convention: default label colour above
25% remaining, orange at ≤25%, red at ≤10%.

## Binary resolution

A GUI app launched from Finder gets a minimal `PATH` that does **not** include
`~/.local/bin`, where `claude` typically lives. Both the interpreter and the CLI
are therefore resolved by absolute path, falling back to `zsh -lc command -v`.
Stock `/usr/bin/python3` (3.9.6) is preferred so no Homebrew install is needed.

Overrides for non-standard installs:

```sh
defaults write com.claudeusagebar.app claudeBin  /path/to/claude
defaults write com.claudeusagebar.app pythonBin  /path/to/python3
defaults write com.claudeusagebar.app parserPath /path/to/claude_usage.py
```

## Caveats

- Depends on the human-readable format of `/usage`, which is undocumented and
  may change; that is what `schema_ok` and the fixture tests are for.
- "Open at Login" uses `SMAppService` and is commonly rejected for unsigned
  builds outside `/Applications`; the app surfaces the error rather than
  failing silently.
