# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A macOS menu bar app (AppKit, no dock icon) showing remaining Claude Code
usage limits, polled for free via `claude --safe-mode -p "/usage"`. A
standalone Python script scrapes that command's human-readable output into a
stable JSON contract; the Swift app renders it.

## Commands

```sh
./build.py                    # SwiftPM release build + hand-assembled .app in dist/
./build.py --install --run    # also copy to /Applications and relaunch
swift build                   # compile only (debug)

swift test                                        # all Swift tests (XCTest)
swift test --filter UsageMachineTests             # one test class
swift test --filter UsageMachineTests/testName    # one test method
python3 tests/test_parser.py                      # parser fixture tests

parser/claude_usage.py --indent 2       # run the scraper, see the JSON contract
parser/claude_usage.py --raw            # underlying /usage text
parser/claude_usage.py --fixture f.txt  # parse a saved capture
```

- Building needs only Xcode Command Line Tools; `swift test` needs full
  Xcode.app (XCTest ships with Xcode, not the CLT). If `xcode-select` points
  at the CLT, run tests with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
- The parser is copied into the app bundle at build time: rebuild after
  editing `parser/claude_usage.py`.
- The lowercase `tests/` directory is deliberate; `Package.swift` sets all
  target paths explicitly.
- This machine's git uses an external columnar diff tool that breaks piping
  or grepping diff output: use `git diff --no-ext-diff` (and `rg`, not
  `grep -P`).

## Architecture

Three layers, separated so the fragile part (scraping an undocumented
command) is testable without the GUI:

- `parser/claude_usage.py` — standalone, stdlib-only (py3.9+). Emits JSON
  with `schema_ok: false` + `missing_keys` when expected `/usage` lines
  disappear, so the app shows `?` instead of a stale or invented number.
  `tests/test_parser.py` runs it against saved fixtures.
- `Sources/ClaudeUsageBarCore/` — all app logic, as a library target so the
  test target can import it. Declarations use the `package` access level;
  synthesized memberwise inits are internal-only, so types built by tests
  need an explicit `package init`.
- `Sources/ClaudeUsageBar/` — entry point only (AppDelegate + NSApp.run()).

### Core: pure state machine + interpreter

`UsageMachine.transition(state, event) -> Step` is the single owner of all
usage-domain state, including preferences and reset-boundary polls. It is
pure and total: no AppKit, no clock reads except the `now` carried in the
event. A `Step` is a nominal struct (state + ordered `[UsageEffect]`) so
tests can assert whole-`Step` equality.

`StatusItemController` (+Menu/+Panel/+Render extensions) is the interpreter:
it owns the NSStatusItem, timer, and fetcher, stamps events with its single
injected clock, commits `step.state`, then performs `step.effects` strictly
in array order — the order is contractual (e.g. `.record` before
`.pollNow`), never reordered or batched.

### Single source of truth for displayed values

- Countdowns come only from `MetricState.remainingSeconds`, recomputed from
  each event's `now`.
- Percentages, gauge/ring fills, and warning bands come only through the
  `MetricPresentation` lens (`UsageState.presentation(for:)`), which resolves
  the Numbers preference (used vs remaining) and severity bands. Drawers
  (`StatusBarRenderer`, `PanelModel`, charts) consume it and never inspect
  the mode or thresholds themselves.

### IO

All IO runs on background queues; the UI must never stall (hard
requirement). `UsageFetcher` runs the parser subprocess on a utility queue,
resolving python/claude by absolute path (GUI apps get a minimal PATH), with
`defaults` overrides `claudeBin`/`pythonBin`/`parserPath`.
`HistoryCoordinator` confines the SQLite `HistoryStore` to one serial
off-main queue and fails hard (`try!`) on post-open errors — a corrupt store
is not a recoverable condition. The bundle id `com.claudeusagebar.app` is
duplicated in `build.py` and `UsageFetcher.swift`; keep them in sync.

### Testing patterns

- `DebugScenario` builds synthetic scenes by folding snapshots through the
  real `UsageMachine.transition` on a fresh machine (effects discarded);
  the Debug menu renders them without touching live state.
- `TestSupport.swift` has `forceDraw(_:)` to execute `NSImage` drawing
  handlers headlessly; visual output can be verified by writing PNGs from
  tests or debug scenarios (screenshots live in the repo, `*.png` is
  gitignored).
- `tmp/` (gitignored via its own `.gitignore`) is the in-repo scratch
  directory.
