# Notch

A tiny, native macOS app that lives around your MacBook's notch and turns it
into a live dashboard for **Claude Code** and **Codex**. No Electron, no
webviews — pure SwiftUI + AppKit, running as a background accessory (no Dock
icon). Only ever shows real data, and uses ~0.1% of one CPU core.

---

## How to run it

You need an Apple Silicon Mac (macOS 14+) and the Swift toolchain. The Xcode
**Command Line Tools** are enough — no full Xcode required:

```bash
xcode-select --install     # if you don't already have the tools
```

Then, from the project folder:

```bash
git clone https://github.com/hamedbecirovic10-del/Notch.git
cd Notch

./build.sh      # 1. compiles a release Notch.app into ./dist
./install.sh    # 2. installs it to ~/Applications and starts it now + at login
```

That's it — look up at your notch. Start a Claude Code or Codex session in a
terminal and the island comes alive.

- **First run with music:** the first time Spotify/Apple Music is playing,
  macOS asks to let Notch read the current track — click **OK**.
- **Rebuild after changing code:** just re-run `./build.sh && ./install.sh`.

### Quit vs. remove

- **Quit anytime:** right-click the notch → **Quit Notch**. It stays quit for
  the rest of the session and comes back automatically at your next login.
- **Remove completely:** `./uninstall.sh` — stops it, removes the login item,
  and deletes both `~/Applications/Notch.app` and the LaunchAgent. This is the
  only thing that stops it from coming back at login.

---

## What it does

- **Idle:** invisible — it draws a black shape exactly over the physical notch,
  so you see nothing until something happens or you hover.
- **Live coding session:** the notch grows into a slim island, flush with the
  menu bar, with the agent's logo + status on the left of the notch and the
  live token count on the right.
- **Hover:** drops into a compact black drawer showing the model, **exactly what
  it's doing right now** ("Editing NotchController.swift", "Running swift build",
  "Thinking…"), and the **tokens and duration of the current prompt**.
- **Finish:** when the turn actually ends it shows a green **Finished** state
  with a success animation, and stays up (with that prompt's stats) while you
  write your next prompt.

### Real numbers, per prompt
Tokens are the **output tokens for the current prompt** — the same "↓ N tokens"
count Claude Code shows in its own status line. They're deduped (Claude writes
each message to its log several times), exclude all cache tokens, and reset on
every new prompt. Duration is the elapsed time of the current prompt. Nothing is
estimated or faked.

### Both agents
Supports **Claude Code** and **Codex**, each with its real logo, showing
whichever was most recently active. Finish is detected precisely from the
transcript (Claude's `stop_reason: end_turn` / Codex's `task_complete`), so it
never falsely says "Finished" mid-work.

It learns everything by tailing the agents' own session transcripts
(`~/.claude/projects/**/*.jsonl` and `~/.codex/sessions/**/*.jsonl`) — reading
token usage, model, and activity straight from disk. Nothing is sent anywhere.

### File shelf
Drag any file(s) onto the notch and it becomes a drop shelf — hold them there,
then drag them back out to anywhere (Finder, an app, an upload field). While
files are held, the shelf takes over and the coding info is hidden.

### Now playing
When Spotify or Apple Music is playing (and no coding session is running), the
island shows the app's real icon, the track, and the artist — iPhone-Dynamic-
Island style. Event-driven (no polling).

### Stays out of the way
In a fullscreen app — where the notch/menu bar isn't visible — Notch hides
itself entirely.

## Performance

- **~0.1% of one CPU core** while active, **~0** when no session is running.
- **FSEvents** (kernel push) for the filesystem and broadcast notifications for
  media — no polling loops.
- The window never resizes; the shape animates inside a fixed transparent
  window with smooth easing, and clicks pass through everywhere except the
  visible shape (so menu-bar items behind it stay clickable).
- The always-visible collapsed island has **no continuous animation** — motion
  only happens on hover, transitions, and the finish burst.
- ~56 MB RSS (standard SwiftUI baseline; most is shared framework memory).

## Project layout

```
Sources/Notch/
  main.swift            – accessory-app entry point (no Dock icon)
  AppDelegate.swift     – boots the controller
  NotchController.swift – floating panel, hover/drag, click-through, quit menu
  NotchGeometry.swift   – notch detection + window framing
  NotchState.swift      – observable UI state
  SessionMonitor.swift  – FSEvents tail of Claude + Codex transcripts
  MediaMonitor.swift    – Spotify / Apple Music now-playing
  Provider.swift        – agents + logo/app-icon loading
  NotchRootView.swift   – the layouts (idle / island / drawer / shelf / media)
  NotchShape.swift      – the notch / dynamic-island silhouette
build.sh · install.sh · uninstall.sh · Info.plist
```

## License

MIT — see [LICENSE](LICENSE).
