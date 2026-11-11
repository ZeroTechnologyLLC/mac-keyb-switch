# mac-keyb-switch (layoutd)

Instant **Cmd+Space** keyboard layout switching on macOS — no keyUp delay, no dropped keystrokes under CPU load.

```
$ make install
```

[README на русском](README.ru.md)

## Why

The stock "Input Sources" hotkey (Cmd+Space) in macOS has two problems:

1. **Switching happens on key release (keyUp)**, not on key press. While you hold Cmd+Space nothing happens — the layout only changes after you let go.
2. **Under CPU load, keystrokes get dropped** (10–30%): the event travels through the symbolic hotkey → WindowServer → TextInputMenuAgent chain, and any overloaded node drops it. Measured on a 12-core stress test: median 364 ms, worst cases 2.4 s, some presses lost entirely.

The switching machinery itself (`TISSelectInputSource`) runs in 2–9 ms.

This is a long-standing and widely reported issue:

- [Keyboard language switch lag, a long standing issue that never gets fixed](https://discussions.apple.com/thread/255940643) — Apple Community: "the classic cmd+space lags unpredictably. Sometimes it works fine, sometimes it doesn't work and takes four times for the input to go through"
- [Cannot switch input language with CMD Space](https://discussions.apple.com/thread/255233761) — Apple Community (Sonoma)
- [Delay/unresponsive on change input](https://developer.apple.com/forums/thread/51454) — Apple Developer Forums
- [Why there is a language switch lag?](https://discussions.apple.com/thread/7769867) — Apple Community (dating back to Sierra)
- [Delay in switching the language layout on mac OS](https://www.reddit.com/r/mac/comments/r2odrh/delay_in_switching_the_language_layout_on_mac_os/) — Reddit

## How it works

`layoutd` is a tiny daemon (a single Swift file, ~250 lines):

1. An active `CGEventTap` (session-level) intercepts Cmd+Space **before the system**
2. On keyDown it calls `TISSelectInputSource` immediately — the layout changes the moment you press
3. keyDown and keyUp are swallowed — the system hotkey never fires a second time
4. Deduplication: under load macOS 27 duplicates events (an UP+DOWN pair 0.0–0.2 ms apart); a DOWN arriving <40 ms after an UP, or <60 ms after a switch, is suppressed

## Benchmark results

| Configuration | Losses under load | Median | Fires on |
|---|---|---|---|
| Cmd+Space (system) | 10–30% | 364 ms | keyUp |
| Caps Lock (system) | 0% | 55 ms | keyDown |
| **Cmd+Space + layoutd** | **0%** | **47–162 ms** | **keyDown** |

Methodology: listenOnly event tap + 1 ms polling of `TISCopyCurrentKeyboardInputSource`; load — 12 busy-loop cores (loadavg 10–43).

## Installation

Requirements: macOS 13+, Xcode Command Line Tools (`xcode-select --install`).

```bash
make install
```

Builds the binary, signs it (if an Apple Development certificate is found), copies it to `~/Library/Application Support/layoutd/`, creates a LaunchAgent and starts it.

**The only manual step** — the Accessibility permission (granted once):

```bash
make accessibility   # opens System Settings → Privacy & Security → Accessibility
```

1. If the list already has **layoutd from a previous install, remove it first** («−»): macOS won't pick up the new entry while the old one with the same signature/name is present
2. «+» → ⌘⇧G → `~/Library/Application Support/layoutd/layoutd` → add

KeepAlive restarts the agent automatically within ~10 seconds after the permission is granted.

## Usage

```bash
make status        # agent state + recent events
make log           # live switching log
make restart       # restart
make stop          # stop
make uninstall     # full removal
```

Custom layouts (default: US ↔ Russian) — set at install time, baked into the LaunchAgent:

```bash
make list                                        # list available Input Source IDs
make install FIRST=com.apple.keylayout.British SECOND=com.apple.keylayout.Russian
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `FATAL: cannot create event tap` | no Accessibility permission | grant it in the pane (see Installation) |
| Not working after reboot | BTS marked the agent `disallowed` (macOS resets background-agent permissions on major updates) | `sfltool dumpbtm \| grep -A12 layoutd` — if `disallowed`, change the Label in the plist (new file name + Label) and `make restart` |
| Switches twice in a row | system event duplicates | already handled by deduplication; if it recurs, run with `--debug` and check intervals in the log |
| Nothing at all in the log | Secure Input (password field in the foreground app) or the tap got disabled | check the frontmost app; `make restart` |

## Technical notes

- **Code signing**: the binary is signed with an Apple Development certificate and a fixed identifier `dev.layoutd` — this keeps the Accessibility permission stable across rebuilds. An adhoc signature binds TCC by cdhash and breaks on every rebuild. If the certificate has expired/been revoked, the Makefile falls back to adhoc and warns — update `SIGN_ID` in the Makefile (`security find-identity -v -p codesigning`).
- **Background Task Management**: after major updates, macOS 27+ may mark a LaunchAgent as `disallowed` — the agent won't start at boot and won't show up in Login Items. Fixed by changing the Label (a clean BTS record).
- **event.timestamp vs DispatchTime.now()**: deduplication compares processing time, not event timestamps — under load, delivery to the tap is unevenly delayed (an UP may arrive after 193 ms, a DOWN after 27 ms), and timestamp comparison misses duplicates.
- **Synthetic posting** of Cmd+Space (CGEvent post) doesn't trigger the symbolic hotkey — system hotkeys filter out synthetic events; measurements are only possible with a listenOnly tap and physical key presses.

## License

MIT
