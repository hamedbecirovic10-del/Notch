import Foundation
import SwiftUI

/// Watches both Claude Code (`~/.claude/projects`) and Codex (`~/.codex/sessions`)
/// transcripts, surfaces whichever was most recently active, and distills it
/// into live UI state. FSEvents (kernel push) — no polling. A 1-second tick
/// runs only while a session is active.
final class SessionMonitor {
    private let state: NotchState
    private let roots: [(url: URL, provider: Provider)]

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.hamed.notch.session", qos: .utility)

    private var currentPath: String?
    private var currentProvider: Provider = .claude
    private var byteOffset: UInt64 = 0

    // Per-prompt (current turn) accounting — reset on every new human prompt.
    private var tokens = 0                 // input + output only, this turn
    private var seenIds = Set<String>()    // dedupe triplicated assistant lines
    private var sessionStart: Date?        // start of the *current* prompt
    private var lastActivity: Date?
    private var codexTurnBase = 0          // Codex cumulative baseline at turn start
    private var codexNonCached = 0

    private var finished = true
    private var activeGeneration = 0

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private func timestamp(_ obj: [String: Any]) -> Date? {
        guard let s = obj["timestamp"] as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private var debounce: DispatchWorkItem?

    // Collected during a parse pass.
    private var pendingModel: String?
    private var pendingStatus: WorkStatus = .thinking
    private var pendingAction = ""
    private var pendingTask: String?

    init(state: NotchState) {
        self.state = state
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots = [
            (home.appendingPathComponent(".claude/projects", isDirectory: true), .claude),
            (home.appendingPathComponent(".codex/sessions", isDirectory: true), .codex),
        ]
    }

    func start() {
        queue.async { [weak self] in
            self?.scan()
            self?.startStream()
        }
    }

    // MARK: FSEvents

    private func startStream() {
        let paths = roots.map(\.url.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<SessionMonitor>.fromOpaque(info).takeUnretainedValue().scheduleScan()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents |
                           kFSEventStreamCreateFlagNoDefer |
                           kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func scheduleScan() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.scan() }
        debounce = w
        queue.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    // MARK: Scan / tail

    private func scan() {
        guard let latest = newestTranscript() else { return }
        if latest.path != currentPath {
            currentPath = latest.path
            currentProvider = latest.provider
            byteOffset = 0
            resetTurn()
            finished = false
        }
        ingest(latest.path)
    }

    private func newestTranscript() -> (path: String, provider: Provider, mtime: Date)? {
        let fm = FileManager.default
        var best: (String, Provider, Date)?
        for root in roots {
            guard let en = fm.enumerator(at: root.url,
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                guard url.pathExtension == "jsonl" else { continue }
                guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                if best == nil || m > best!.2 { best = (url.path, root.provider, m) }
            }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    private func ingest(_ path: String) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: byteOffset) } catch { return }
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        byteOffset += UInt64(data.count)

        var activity = false
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            let handled = (currentProvider == .claude)
                ? parseClaude(Data(line))
                : parseCodex(Data(line))
            if handled { activity = true }
        }
        guard activity else { return }
        if pendingStatus != .finished { finished = false }
        markActivity()
        push()
        if pendingStatus == .finished { onFinished() }
    }

    // MARK: Claude parsing

    private func resetTurn() {
        tokens = 0
        seenIds.removeAll(keepingCapacity: true)
        sessionStart = nil
        codexTurnBase = codexNonCached
    }

    private func parseClaude(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        switch obj["type"] as? String {
        case "assistant":
            guard let msg = obj["message"] as? [String: Any] else { return false }
            if let m = msg["model"] as? String { pendingModel = friendlyModel(m) }
            // Claude Code writes each assistant message several times; count its
            // usage once. Output tokens only — this matches Claude Code's own
            // "↓ N tokens" status readout for the current prompt.
            let id = (msg["id"] as? String) ?? UUID().uuidString
            if !seenIds.contains(id), let u = msg["usage"] as? [String: Any] {
                seenIds.insert(id)
                tokens += (u["output_tokens"] as? Int ?? 0)
            }
            if sessionStart == nil { sessionStart = timestamp(obj) ?? Date() }
            lastActivity = timestamp(obj) ?? Date()
            let stop = msg["stop_reason"] as? String
            if stop == "tool_use" || stop == nil {
                let (st, act) = claudeToolStatus(msg["content"])
                pendingStatus = st
                pendingAction = act
            } else {
                pendingStatus = .finished          // end_turn / stop_sequence / max_tokens
                pendingAction = ""
            }
            return true
        case "user":
            // A new human turn resets the per-prompt counters. This must fire
            // for ANY real prompt — including slash commands and image-only
            // messages that have no clean text line — but NOT for tool results.
            guard let m = obj["message"] as? [String: Any], isHumanTurn(m["content"]) else { return false }
            resetTurn()
            sessionStart = timestamp(obj) ?? Date()
            lastActivity = sessionStart
            if let t = humanPrompt(m) { pendingTask = t }   // may stay as prior task for slash cmds
            pendingStatus = .thinking
            pendingAction = "Thinking…"
            return true
        default:
            return false
        }
    }

    /// True when a user message is an actual human turn (not a tool result).
    private func isHumanTurn(_ content: Any?) -> Bool {
        if content is String { return true }
        if let arr = content as? [[String: Any]] {
            let hasToolResult = arr.contains { ($0["type"] as? String) == "tool_result" }
            let hasText = arr.contains { ($0["type"] as? String) == "text" }
            return hasText || !hasToolResult
        }
        return false
    }

    private func claudeToolStatus(_ content: Any?) -> (WorkStatus, String) {
        guard let arr = content as? [[String: Any]] else { return (.thinking, "Thinking…") }
        for item in arr where (item["type"] as? String) == "tool_use" {
            let name = item["name"] as? String ?? ""
            let input = item["input"] as? [String: Any] ?? [:]
            switch name {
            case "Edit", "Write", "MultiEdit", "NotebookEdit":
                return (.editing, "Editing " + baseName(input["file_path"] as? String))
            case "Bash":
                let cmd = (input["command"] as? String) ?? ""
                return (.running, "Running " + firstWords(cmd, 4))
            case "Read":
                return (.running, "Reading " + baseName(input["file_path"] as? String))
            case "Grep", "Glob":
                return (.running, "Searching")
            case "Task":
                return (.running, "Delegating a subtask")
            case "WebFetch", "WebSearch":
                return (.running, "Searching the web")
            default:
                return (.running, name.isEmpty ? "Working" : name)
            }
        }
        return (.thinking, "Thinking…")
    }

    // MARK: Codex parsing

    private func parseCodex(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return false }
        let ptype = payload["type"] as? String

        // Model can appear in session meta / turn context.
        if let m = payload["model"] as? String { pendingModel = friendlyModel(m) }
        if let ctx = payload["turn_context"] as? [String: Any], let m = ctx["model"] as? String {
            pendingModel = friendlyModel(m)
        }

        switch obj["type"] as? String {
        case "event_msg":
            if ptype == "token_count", let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any] {
                // Output tokens only, per-turn = delta since this prompt began
                // (mirrors the "↓ N tokens" readout).
                codexNonCached = (total["output_tokens"] as? Int ?? 0)
                tokens = max(0, codexNonCached - codexTurnBase)
                return true
            }
            if ptype == "task_complete" {
                pendingStatus = .finished
                pendingAction = ""
                lastActivity = timestamp(obj) ?? Date()
                return true
            }
            return false
        case "response_item":
            if sessionStart == nil { sessionStart = timestamp(obj) ?? Date() }
            lastActivity = timestamp(obj) ?? Date()
            switch ptype {
            case "function_call", "local_shell_call", "custom_tool_call":
                let name = (payload["name"] as? String) ?? "shell"
                let (st, act) = codexToolStatus(name, payload)
                pendingStatus = st; pendingAction = act
                return true
            case "reasoning":
                pendingStatus = .thinking; pendingAction = "Thinking…"
                return true
            case "message":
                if (payload["role"] as? String) == "user" {
                    resetTurn()
                    sessionStart = timestamp(obj) ?? Date()
                    lastActivity = sessionStart
                    if let t = codexUserText(payload["content"]) { pendingTask = t }
                    pendingStatus = .thinking; pendingAction = "Thinking…"
                } else {
                    pendingStatus = .thinking; pendingAction = "Responding…"
                }
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    private func codexToolStatus(_ name: String, _ payload: [String: Any]) -> (WorkStatus, String) {
        let n = name.lowercased()
        if n.contains("patch") || n.contains("edit") || n.contains("write") {
            return (.editing, "Editing files")
        }
        if n.contains("shell") || n.contains("exec") || n.contains("bash") {
            var cmd = ""
            if let args = payload["arguments"] as? String,
               let d = args.data(using: .utf8),
               let a = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                if let c = a["command"] as? [String] { cmd = c.joined(separator: " ") }
                else if let c = a["command"] as? String { cmd = c }
            }
            return (.running, "Running " + firstWords(cmd, 4))
        }
        if n.contains("read") { return (.running, "Reading files") }
        return (.running, name)
    }

    private func codexUserText(_ content: Any?) -> String? {
        if let s = content as? String { return firstHumanLine(s) }
        if let arr = content as? [[String: Any]] {
            for item in arr {
                if let t = item["text"] as? String, let line = firstHumanLine(t) { return line }
            }
        }
        return nil
    }

    // MARK: Finish → idle

    private func markActivity() {
        activeGeneration &+= 1
    }

    private func onFinished() {
        finished = true
        // Keep showing "Finished" (with this prompt's tokens & duration) so it
        // stays up while you write the next prompt. Only fade to idle after a
        // long stretch of no activity — i.e. you've clearly walked away.
        let gen = activeGeneration
        queue.asyncAfter(deadline: .now() + 600) { [weak self] in
            guard let self, self.activeGeneration == gen else { return }
            DispatchQueue.main.async { [weak self] in
                guard let s = self?.state else { return }
                if s.status == .finished {
                    withAnimation(.smooth(duration: 0.5)) {
                        s.status = .idle
                        s.provider = nil
                        s.currentAction = ""
                    }
                }
            }
        }
    }

    // MARK: Push to UI

    private func push() {
        let provider = currentProvider
        let model = pendingModel ?? provider.displayName
        let status = pendingStatus
        let action = pendingAction
        let task = pendingTask
        let tokens = self.tokens
        let start = sessionStart
        let activity = lastActivity
        DispatchQueue.main.async { [weak state] in
            guard let state else { return }
            let wasFinished = state.status == .finished
            state.provider = provider
            state.modelName = model
            state.totalTokens = tokens
            if let task, !task.isEmpty { state.task = task }
            state.sessionStart = start
            state.lastActivity = activity
            state.currentAction = action
            if state.status != status {
                withAnimation(.smooth(duration: 0.42)) {
                    state.status = status
                }
                if status == .finished && !wasFinished { state.successPulse &+= 1 }
            }
        }
    }

    // MARK: Helpers

    private func baseName(_ path: String?) -> String {
        guard let p = path, !p.isEmpty else { return "a file" }
        return (p as NSString).lastPathComponent
    }

    private func firstWords(_ s: String, _ n: Int) -> String {
        let words = s.split(whereSeparator: { $0 == " " || $0 == "\n" }).prefix(n).joined(separator: " ")
        return words.isEmpty ? "a command" : words
    }

    private func friendlyModel(_ id: String) -> String {
        let l = id.lowercased()
        if l.contains("fable") { return "Fable 5" }
        if l.contains("mythos") { return "Mythos 5" }
        if l.contains("opus") { return "Opus 4.8" }
        if l.contains("sonnet") { return "Sonnet 5" }
        if l.contains("haiku") { return "Haiku 4.5" }
        if l.contains("gpt-5") || l.contains("gpt5") { return "GPT-5" }
        if l.hasPrefix("o3") { return "o3" }
        if l.hasPrefix("o4") { return "o4" }
        if l.contains("codex") { return "Codex" }
        return id
    }

    private static let noise = [
        "displayed at", "Multiply coordinates", "system-reminder", "<command",
        "</command", "command-name", "command-message", "command-args",
        "local-command", "Caveat:", "This session", "SessionStart",
        "IMPORTANT:", "Analysis of", "stdout", "[Image", "[Request interrupted",
    ]

    private func firstHumanLine(_ s: String) -> String? {
        for raw in s.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.count < 3 { continue }
            if line.hasPrefix("<") || line.hasPrefix("[") || line.hasPrefix("{") { continue }
            if line.hasPrefix("/") && !line.contains(" ") { continue }
            if Self.noise.contains(where: { line.contains($0) }) { continue }
            return line.count > 60 ? String(line.prefix(59)) + "…" : line
        }
        return nil
    }

    private func humanPrompt(_ message: Any?) -> String? {
        guard let m = message as? [String: Any] else { return nil }
        if let s = m["content"] as? String { return firstHumanLine(s) }
        if let arr = m["content"] as? [[String: Any]] {
            for item in arr {
                if (item["type"] as? String) == "tool_result" { return nil }
                if (item["type"] as? String) == "text", let t = item["text"] as? String,
                   let line = firstHumanLine(t) { return line }
            }
        }
        return nil
    }
}
