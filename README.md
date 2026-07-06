# Notch

A tiny, native macOS app that lives around your MacBook's notch and turns it
into a live dashboard for Claude Code. No Electron, no webviews — pure
SwiftUI + AppKit, running as a background accessory (no Dock icon).

![states: idle → live island → expanded drawer]

## What it does

- **Idle:** invisible. The app draws a black shape exactly over the physical
  notch, so you don't see anything until something is happening or you hover.
- **Live coding session:** the notch grows into a slim island — flush with the
  menu bar — that flanks the cut-out with the agent's logo + status on the left
  and the token count on the right.
- **Hover:** drops into a compact Liquid-Glass drawer showing the model,
  **exactly what it's doing right now** ("Editing NotchController.swift",
  "Running swift build", "Thinking…"), and the **tokens and duration of the
  current prompt**. Tokens are input + output only (never cache), deduped, and
  reset every new prompt — so the number is real and matches your session.
- **Finish:** when the turn actually ends it shows a green **Finished** state
  with a success animation, and stays up (with that prompt's stats) while you
  write your next prompt.

### Both agents
It supports **Claude Code** and **Codex**, with each one's real logo, and shows
whichever was most recently active. Finish is detected precisely from the
transcript (Claude's `stop_reason: end_turn` / Codex's `task_complete`), so it
never falsely says "Finished" mid-work.

It learns everything by tailing the agents' own session transcripts
(`~/.claude/projects/**/*.jsonl` and `~/.codex/sessions/**/*.jsonl`) — reading
token usage, model, tool activity, and prompts straight from disk. Nothing is
sent anywhere, and only real data is ever shown.

### File shelf
Drag any file(s) onto the notch and it turns into a drop shelf — hold them
there, then drag them back out to anywhere (Finder, an app, an upload field).
While files are held, the shelf takes over and the coding info is hidden.

### Now playing
When Spotify or Apple Music is playing (and no coding session is running), the
island shows the app's real icon, the track, and the artist — iPhone-Dynamic-
Island style. Driven by the apps' broadcast notifications (no polling); track
details are read with a short AppleScript, so the first time you play something
macOS will ask to let Notch read that app.

### Stays out of the way
When you're in a fullscreen app — where the notch/menu bar isn't visible — Notch
hides itself entirely.

## Performance

- **~0.1% of one CPU core** at rest, and literally **0** when no Claude session
  is running.
- Uses **FSEvents** (kernel push) for the filesystem and broadcast
  notifications for media — no polling loops. The 1-second clock tick only runs
  *while a session is active* and stops itself.
- The window never resizes; the shape animates inside a fixed transparent
  window, and clicks pass through everywhere except the visible shape (so
  menu-bar items behind it stay clickable). Hover animation is buttery.
- The always-visible collapsed island has **no continuous animation** — motion
  only happens on hover, transitions, and the finish burst — so a live session
  costs ~0.1% of one core.
- ~56 MB RSS (standard SwiftUI baseline; most is shared framework memory).

## Install

```bash
./build.sh      # compiles a release Notch.app into ./dist
./install.sh    # copies it to ~/Applications and starts it at login
```

`install.sh` registers a LaunchAgent, so Notch starts automatically at every
login.

## Quitting vs. removing

- **Quit anytime:** right-click the notch → **Quit Notch** (⌘Q in the menu).
  It stays quit for the rest of the session, and comes back at your next login.
- **Remove permanently:** run `./uninstall.sh`. That stops the process,
  unregisters the login item, and deletes both the app bundle
  (`~/Applications/Notch.app`) and the LaunchAgent plist.

## Requirements

- Apple Silicon Mac, macOS 14+ (built and tested on macOS 26).
- Swift toolchain (Command Line Tools are enough — no full Xcode needed).

## Project layout

```
Sources/Notch/
  main.swift            – accessory-app entry point
  AppDelegate.swift     – boots the controller
  NotchController.swift – the floating panel, hover/drag, animated resizing
  NotchGeometry.swift   – notch detection + window framing
  NotchState.swift      – observable UI state
  ClaudeMonitor.swift   – FSEvents tail of Claude's transcripts
  NotchRootView.swift   – the three layouts (idle / island / drawer)
  NotchShape.swift      – the notch/dynamic-island silhouette
  ClaudeMark.swift      – the Claude "spark" mark, drawn with Canvas
```
