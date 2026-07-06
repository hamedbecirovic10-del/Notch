import AppKit

/// A coding agent whose activity we surface at the notch.
enum Provider: Equatable {
    case claude
    case codex
    case grok

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .grok:   return "Grok"
        }
    }

    var resourceName: String {
        switch self {
        case .claude: return "claude"
        case .codex:  return "codex"
        case .grok:   return "grok"
        }
    }
}

/// Loads the real brand logos bundled in Resources, once.
enum ProviderLogos {
    static let claude: NSImage? = load("claude")
    static let codex: NSImage? = load("codex")
    static let grok: NSImage? = load("grok")

    static func image(for p: Provider) -> NSImage? {
        switch p {
        case .claude: return claude
        case .codex:  return codex
        case .grok:   return grok
        }
    }

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = false
        return img
    }
}

/// Bundled resource images (widget icons etc.), loaded once.
enum Assets {
    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let c = cache[name] { return c }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }
}

/// Real app icons (e.g. Spotify, Music) by bundle id, cached.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    static func image(bundleID: String) -> NSImage? {
        if let c = cache[bundleID] { return c }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
