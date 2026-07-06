import AppKit

// Accessory app: no Dock icon, no menu bar item, lives entirely at the notch.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
