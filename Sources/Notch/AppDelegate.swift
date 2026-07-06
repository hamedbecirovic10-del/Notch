import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NotchController()
        controller.start()
        self.controller = controller
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
