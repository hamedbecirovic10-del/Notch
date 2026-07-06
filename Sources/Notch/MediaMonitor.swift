import Foundation
import AppKit

/// Fire playback commands at the current media app via AppleScript.
enum MediaControls {
    static func run(_ media: MediaInfo?, _ command: String) {
        guard let app = media?.appName else { return }
        let src = "tell application \"\(app)\" to \(command)"
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
        }
    }
    static func playPause(_ m: MediaInfo?) { run(m, "playpause") }
    static func next(_ m: MediaInfo?)      { run(m, "next track") }
    static func previous(_ m: MediaInfo?)  { run(m, "previous track") }
}

/// Now-playing for Spotify and Apple Music, iPhone-Dynamic-Island style.
/// Both apps broadcast a DistributedNotification on every play/pause/track
/// change; we use that as the trigger and read authoritative track info via a
/// short AppleScript (only when the app is already running — never launches
/// it). Fully event-driven, no polling.
final class MediaMonitor {
    private let state: NotchState
    private let queue = DispatchQueue(label: "com.hamed.notch.media", qos: .utility)

    private struct Player { let name: String; let bundleID: String }
    private let spotify = Player(name: "Spotify", bundleID: "com.spotify.client")
    private let music = Player(name: "Music", bundleID: "com.apple.Music")

    init(state: NotchState) { self.state = state }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(spotifyChanged),
                        name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil)
        dnc.addObserver(self, selector: #selector(musicChanged),
                        name: NSNotification.Name("com.apple.Music.playerInfo"), object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appLaunchedOrActivated(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appLaunchedOrActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        // Pick up whatever is already playing at launch.
        queue.async { [weak self] in
            guard let self else { return }
            self.refresh(self.spotify)
            self.refresh(self.music)
        }
    }

    @objc private func spotifyChanged() { queue.async { [weak self] in self.map { $0.refresh($0.spotify) } } }
    @objc private func musicChanged() { queue.async { [weak self] in self.map { $0.refresh($0.music) } } }

    @objc private func appLaunchedOrActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier
        else { return }
        let launched = note.name == NSWorkspace.didLaunchApplicationNotification
        if bundleID == spotify.bundleID {
            refreshForLaunchOrActivation(spotify, launched: launched)
        } else if bundleID == music.bundleID {
            refreshForLaunchOrActivation(music, launched: launched)
        }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier
        else { return }
        if bundleID == spotify.bundleID {
            clearIfCurrent(spotify.name)
        } else if bundleID == music.bundleID {
            clearIfCurrent(music.name)
        }
    }

    private func scheduleRefresh(_ p: Player, delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh(p) }
    }

    private func refreshForLaunchOrActivation(_ p: Player, launched: Bool) {
        scheduleRefresh(p, delay: launched ? 0.2 : 0)
        if launched { scheduleRefresh(p, delay: 1.0) }
    }

    private func refresh(_ p: Player) {
        guard isRunning(p.bundleID) else { clearIfCurrent(p.name); return }
        guard let out = runScript(app: p.name) else { clearIfCurrent(p.name); return }
        let parts = out.components(separatedBy: "\n")
        let stateStr = parts.indices.contains(0) ? parts[0] : ""
        let title = parts.indices.contains(1) ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let artist = parts.indices.contains(2) ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let stopped = stateStr.lowercased().contains("stopped")
        let playing = stateStr.lowercased().contains("playing")
        let info = MediaInfo(appName: p.name, bundleID: p.bundleID,
                             title: title, artist: artist, isPlaying: playing)
        DispatchQueue.main.async { [weak state] in
            guard let state else { return }
            if !stopped && !title.isEmpty {
                state.media = info
            } else if state.media?.appName == p.name {
                state.media = nil
            }
        }
    }

    private func clearIfCurrent(_ name: String) {
        DispatchQueue.main.async { [weak state] in
            if state?.media?.appName == name { state?.media = nil }
        }
    }

    private func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private func runScript(app: String) -> String? {
        let src = """
        tell application "\(app)"
            set s to (player state as string)
            set n to ""
            set a to ""
            if s is not "stopped" then
                try
                    set n to name of current track
                    set a to artist of current track
                end try
            end if
            return s & "\n" & n & "\n" & a
        end tell
        """
        var err: NSDictionary?
        guard let script = NSAppleScript(source: src) else { return nil }
        let result = script.executeAndReturnError(&err)
        if err != nil { return nil }
        return result.stringValue
    }
}
