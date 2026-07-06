import Foundation
import SwiftUI

/// Watches both Claude Code (`~/.claude/projects`) and Codex (`~/.codex/sessions`)
/// transcripts, surfaces whichever was most recently active, and distills it
/// into live UI state. FSEvents (kernel push) — no polling, no timers; the
/// duration clock is driven by the SwiftUI drawer only while it's open.
final class SessionMonitor {
    private let state: NotchState
    private let roots: [(url: URL, provider: Provider)]

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.hamed.notch.session", qos: .utility)

    private var currentPath: String?
    private var currentProvider: Provider = .claude
    private var byteOffset: UInt64 = 0

    // Per-prompt (current turn) accounting — reset on every new human prompt.
    private var tokens = 0                 // output tokens only, this turn
    private var seenIds = Set<String>()    // dedupe triplicated assistant lines
    private var sessionStart: Date?        // start of the *current* prompt
    private var lastActivity: Date?
    private var codexTurnBase = 0          // Codex cumulative baseline at turn start
    private var codexNonCached = 0
    private var grokTurnBase = 0           // Grok cumulative baseline at turn start
    private var grokTokensUsed = 0
    // A single user submission can log several user-role lines (image metadata,
    // slash-command tags, command output, the stop-hook message). We must reset
    // the turn only ONCE per submission — on the first user line after the
    // assistant — not on every injected line.
    private var sawAssistantSinceReset = false

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
            (home.appendingPathComponent(".grok/sessions", isDirectory: true), .grok),
        ]
    }

    private var staleTimer: DispatchSourceTimer?

    func start() {
        queue.async { [weak self] in
            self?.scan()
            self?.startStream()
            self?.startStaleTimer()
        }
    }

    /// The transcript only changes while an agent is writing. If it goes quiet
    /// for a while the session was closed (or finished and abandoned) — hide it
    /// so a closed Claude/Codex/Grok doesn't linger, and stale files never show
    /// a frozen 0-token reading.
    private func startStaleTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 8, repeating: 8)
        t.setEventHandler { [weak self] in self?.checkStale() }
        staleTimer = t
        t.resume()
    }

    private func checkStale() {
        guard let path = currentPath,
              let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        else { return }
        let age = Date().timeIntervalSince(mtime)
        // Finished+quiet hides fast; an in-progress turn tolerates long thinking
        // gaps (Claude can reason for a while without writing).
        let limit: TimeInterval = (pendingStatus == .finished) ? 40 : 240
        guard age > limit else { return }
        DispatchQueue.main.async { [weak state] in
            guard let s = state, s.provider != nil else { return }
            withAnimation(.smooth(duration: 0.45)) {
                s.status = .idle
                s.provider = nil
                s.currentAction = ""
            }
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
                                          0.1, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func scheduleScan() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.scan() }
        debounce = w
        queue.asyncAfter(deadline: .now() + 0.04, execute: w)
    }

    // MARK: Scan / tail

    private func scan() {
        guard let latest = newestTranscript() else { return }
        if latest.path != currentPath {
            currentPath = latest.path
            currentProvider = latest.provider
            byteOffset = 0
            resetTurn(clearSessionMetadata: true)
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
                // Grok spreads a session across several .jsonl files; the
                // events log is the live status stream we follow.
                if root.provider == .grok && url.lastPathComponent != "events.jsonl" { continue }
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
            let handled: Bool
            switch currentProvider {
            case .claude: handled = parseClaude(Data(line))
            case .codex:  handled = parseCodex(Data(line))
            case .grok:   handled = parseGrok(Data(line))
            }
            if handled { activity = true }
        }
        if currentProvider == .grok { readGrokTokens(near: path) }
        guard activity else { return }
        if pendingStatus != .finished { finished = false }
        markActivity()
        push()
        if pendingStatus == .finished { onFinished() }
    }

    // MARK: Claude parsing

    private func resetTurn(clearSessionMetadata: Bool = false) {
        tokens = 0
        seenIds.removeAll(keepingCapacity: true)
        sessionStart = nil
        codexTurnBase = codexNonCached
        grokTurnBase = grokTokensUsed
        if clearSessionMetadata {
            pendingModel = nil
            pendingTask = nil
            pendingAction = ""
            pendingStatus = .thinking
            lastActivity = nil
        }
    }

    private func parseClaude(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        switch obj["type"] as? String {
        case "assistant":
            guard let msg = obj["message"] as? [String: Any] else { return false }
            sawAssistantSinceReset = true
            if let m = msg["model"] as? String, !isSyntheticModel(m) {
                pendingModel = friendlyModel(m)
            }
            // Claude Code writes each assistant message several times; count its
            // usage once. Input + output (never cache) — this matches the token
            // number Claude Code shows for the current prompt.
            let id = (msg["id"] as? String) ?? UUID().uuidString
            if !seenIds.contains(id), let u = msg["usage"] as? [String: Any] {
                seenIds.insert(id)
                tokens += (u["input_tokens"] as? Int ?? 0)
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
            // A user submission logs several user-role lines; reset the turn only
            // on the first one after the assistant (not tool results).
            guard let m = obj["message"] as? [String: Any], isHumanTurn(m["content"]) else { return false }
            if sawAssistantSinceReset {
                resetTurn()
                sawAssistantSinceReset = false
            }
            if sessionStart == nil { sessionStart = timestamp(obj) ?? Date() }
            lastActivity = timestamp(obj) ?? Date()
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
                // Input (non-cached) + output, per-turn = delta since this prompt
                // began. Matches Codex's own per-turn token accounting.
                let inp = (total["input_tokens"] as? Int ?? 0)
                let cached = (total["cached_input_tokens"] as? Int ?? 0)
                let out = (total["output_tokens"] as? Int ?? 0)
                codexNonCached = max(0, inp - cached) + out
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
                sawAssistantSinceReset = true
                let name = (payload["name"] as? String) ?? "shell"
                let (st, act) = codexToolStatus(name, payload)
                pendingStatus = st; pendingAction = act
                return true
            case "reasoning":
                sawAssistantSinceReset = true
                pendingStatus = .thinking; pendingAction = "Thinking…"
                return true
            case "message":
                if (payload["role"] as? String) == "user" {
                    if sawAssistantSinceReset {
                        resetTurn()
                        sawAssistantSinceReset = false
                    }
                    if sessionStart == nil { sessionStart = timestamp(obj) ?? Date() }
                    lastActivity = timestamp(obj) ?? Date()
                    if let t = codexUserText(payload["content"]) { pendingTask = t }
                    pendingStatus = .thinking; pendingAction = "Thinking…"
                } else {
                    sawAssistantSinceReset = true
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

    // MARK: Grok parsing (events.jsonl for status; updates.jsonl for tokens)

    private func parseGrok(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return false }
        let ts = grokTimestamp(obj)
        switch type {
        case "turn_started":
            resetTurn()
            if let m = obj["model_id"] as? String { pendingModel = friendlyModel(m) }
            sessionStart = ts ?? Date()
            lastActivity = sessionStart
            pendingStatus = .thinking
            pendingAction = "Thinking…"
            return true
        case "phase_changed":
            switch obj["phase"] as? String {
            case "streaming_reasoning", "waiting_for_model", "streaming_text":
                if pendingStatus != .editing && pendingStatus != .running {
                    pendingStatus = .thinking; pendingAction = "Thinking…"
                }
            case "tool_execution", "permission_prompt":
                if pendingStatus != .editing { pendingStatus = .running }
            default: break
            }
            if sessionStart == nil { sessionStart = ts ?? Date() }
            lastActivity = ts ?? Date()
            return true
        case "tool_started":
            let (st, act) = grokToolStatus(obj["tool_name"] as? String ?? "")
            pendingStatus = st; pendingAction = act
            if sessionStart == nil { sessionStart = ts ?? Date() }
            lastActivity = ts ?? Date()
            return true
        case "turn_ended":
            pendingStatus = .finished; pendingAction = ""
            lastActivity = ts ?? Date()
            return true
        default:
            return false
        }
    }

    private func grokToolStatus(_ name: String) -> (WorkStatus, String) {
        let n = name.lowercased()
        if n.contains("replace") || n.contains("edit") || n.contains("write") || n.contains("create") {
            return (.editing, "Editing files")
        }
        if n.contains("bash") || n.contains("shell") || n.contains("exec") || n.contains("command") {
            return (.running, "Running a command")
        }
        if n.contains("read") || n.contains("view") { return (.running, "Reading files") }
        if n.contains("search") || n.contains("grep") || n.contains("glob") || n.contains("find") {
            return (.running, "Searching")
        }
        return (.running, name.isEmpty ? "Working" : name)
    }

    private func grokTimestamp(_ obj: [String: Any]) -> Date? {
        guard let s = obj["ts"] as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Grok records token usage in the sibling `updates.jsonl`; read the most
    /// recent `tokens_used` (its own real per-session count).
    private func readGrokTokens(near eventsPath: String) {
        let updates = (eventsPath as NSString).deletingLastPathComponent + "/updates.jsonl"
        guard let content = try? String(contentsOfFile: updates, encoding: .utf8) else { return }
        for line in content.split(separator: "\n").reversed() where line.contains("tokens_used") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let params = o["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  let t = update["tokens_used"] as? Int else { continue }
            grokTokensUsed = t
            tokens = t
            return
        }
    }

    // MARK: Finish → idle

    private func markActivity() {
        activeGeneration &+= 1
    }

    private func onFinished() {
        finished = true
        // Hiding is handled by the staleness timer: "Finished" stays up while
        // you write the next prompt, then the session fades out once its log
        // has been quiet for a while (or the agent is closed).
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
        let raw = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = raw.lowercased()
        if l.contains("fable") { return claudeFamily("Fable", marker: "fable", in: l) }
        if l.contains("mythos") { return claudeFamily("Mythos", marker: "mythos", in: l) }
        if l.contains("opus") { return claudeFamily("Opus", marker: "opus", in: l) }
        if l.contains("sonnet") { return claudeFamily("Sonnet", marker: "sonnet", in: l) }
        if l.contains("haiku") { return claudeFamily("Haiku", marker: "haiku", in: l) }
        if l.hasPrefix("gpt-") { return "GPT-" + raw.dropFirst(4) }
        if l.hasPrefix("gpt") { return "GPT" + raw.dropFirst(3) }
        if l.hasPrefix("o3") { return "o3" }
        if l.hasPrefix("o4") { return "o4" }
        if l.contains("codex") { return "Codex" }
        if l.contains("grok") {
            if l.contains("build") { return "Grok Build" }
            if l.contains("4") { return "Grok 4" }
            return "Grok"
        }
        return raw.isEmpty ? id : raw
    }

    private func isSyntheticModel(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "<synthetic>"
    }

    private func claudeFamily(_ display: String, marker: String, in lower: String) -> String {
        if let version = claudeVersion(marker: marker, in: lower) {
            return "\(display) \(version)"
        }
        return display
    }

    private func claudeVersion(marker: String, in lower: String) -> String? {
        let parts = lower.split(separator: "-").map(String.init)
        guard let idx = parts.firstIndex(of: marker) else { return nil }
        var after: [String] = []
        for part in parts.dropFirst(idx + 1) {
            guard isVersionToken(part) else { break }
            after.append(part)
            if after.count == 2 { break }
        }
        if !after.isEmpty { return after.joined(separator: ".") }
        if idx >= 2, isVersionToken(parts[idx - 2]), isVersionToken(parts[idx - 1]) {
            return parts[(idx - 2)...(idx - 1)].joined(separator: ".")
        }
        if idx >= 1, isVersionToken(parts[idx - 1]) {
            return parts[idx - 1]
        }
        return nil
    }

    private func isVersionToken(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 2 && value.allSatisfy(\.isNumber)
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
