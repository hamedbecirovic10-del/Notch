import SwiftUI

enum WorkStatus: Equatable {
    case idle
    case thinking
    case editing
    case running
    case finished

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .editing: return "Editing"
        case .running: return "Running"
        case .finished: return "Finished"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "moon.zzz.fill"
        case .thinking: return "sparkle"
        case .editing: return "pencil"
        case .running: return "terminal.fill"
        case .finished: return "checkmark"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .thinking: return Color(red: 0.82, green: 0.60, blue: 0.98)
        case .editing: return Color(red: 0.42, green: 0.72, blue: 1.0)
        case .running: return Color(red: 0.42, green: 0.86, blue: 0.62)
        case .finished: return Color(red: 0.36, green: 0.86, blue: 0.52)
        }
    }

    var isActive: Bool { self == .thinking || self == .editing || self == .running }
}

struct MediaInfo: Equatable {
    var appName: String
    var bundleID: String
    var title: String
    var artist: String
    var isPlaying: Bool
}

/// What the notch is currently presenting. Higher entries win.
enum Presentation: Equatable {
    case files      // a drag is happening, or files are being held
    case coding     // a Claude/Codex session is live or just finished
    case media      // music is playing and nothing else is going on
    case idle
}

@MainActor
final class NotchState: ObservableObject {
    // Interaction
    @Published var isExpanded = false
    @Published var isDragOver = false
    @Published var droppedFiles: [URL] = []

    // Coding session
    @Published var provider: Provider? = nil
    @Published var status: WorkStatus = .idle
    @Published var modelName = ""
    @Published var totalTokens = 0
    @Published var currentAction = ""
    @Published var task = ""
    @Published var sessionStart: Date? = nil
    @Published var lastActivity: Date? = nil
    @Published var successPulse = 0

    // Media
    @Published var media: MediaInfo? = nil

    var presentation: Presentation {
        if isDragOver || !droppedFiles.isEmpty { return .files }
        if provider != nil && status != .idle { return .coding }
        if let m = media, m.isPlaying { return .media }
        return .idle
    }

    var isSessionActive: Bool { presentation == .coding }

    var durationString: String {
        guard let start = sessionStart else { return "0s" }
        let ref = (status == .finished ? (lastActivity ?? Date()) : Date())
        let secs = max(0, Int(ref.timeIntervalSince(start)))
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60, s = secs % 60
        if m < 60 { return "\(m)m \(s)s" }
        return "\(m / 60)h \(m % 60)m"
    }

    var tokenString: String { NotchState.compact(totalTokens) }

    /// Always one decimal place in the K/M range (e.g. 20.0K, 25.8K, 1.2M).
    static func compact(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fK", Double(n) / 1000.0) }
        return String(format: "%.1fM", Double(n) / 1_000_000.0)
    }

    // MARK: - Idle widgets (calendar / timer / media)

    let calendar = CalendarStore()
    @Published var widgetPage = 0          // 0 = calendar, 1 = timer, 2 = media

    // Countdown timer
    @Published var timerMinutes = 25       // selected duration on the dial
    @Published var timerEndDate: Date? = nil
    @Published var timerRunning = false

    func startTimer() {
        timerEndDate = Date().addingTimeInterval(Double(max(1, timerMinutes)) * 60)
        timerRunning = true
    }
    func stopTimer() {
        timerRunning = false
        timerEndDate = nil
    }
    /// Remaining seconds, or the selected duration when idle.
    func timerDisplay(now: Date) -> String {
        let secs: Int
        if timerRunning, let end = timerEndDate {
            secs = max(0, Int(end.timeIntervalSince(now).rounded()))
        } else {
            secs = timerMinutes * 60
        }
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}
