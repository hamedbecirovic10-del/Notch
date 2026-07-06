import AppKit
import SwiftUI
import Combine

/// Borderless, non-activating, transparent panel floating over the menu bar.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
}

/// Content view: hosts SwiftUI, passes clicks through everywhere except the
/// visible shape (so menu-bar items behind stay clickable), tracks hover on
/// exactly the shape, and is the file drop target.
final class ShapeContainer: NSView {
    weak var controller: NotchController?
    var shapeRect: () -> CGRect = { .zero }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
        refreshTracking()
    }

    func refreshTracking() {
        for ta in trackingAreas { removeTrackingArea(ta) }
        let r = shapeRect()
        guard r.width > 0 else { return }
        addTrackingArea(NSTrackingArea(rect: r,
            options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: nil)   // window → view coords
        return shapeRect().contains(local) ? super.hitTest(point) : nil
    }

    override func mouseEntered(with event: NSEvent) { controller?.hover(true) }
    override func mouseExited(with event: NSEvent) { controller?.hover(false) }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Notch", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Notch", action: #selector(quitNotch), keyEquivalent: "q"))
        menu.items.last?.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func quitNotch() { NSApp.terminate(nil) }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { controller?.dragEntered(); return .copy }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ s: NSDraggingInfo?) { controller?.dragExited() }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let urls = (s.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        controller?.dropped(urls)
        return true
    }
}

@MainActor
final class NotchController {
    let state = NotchState()
    private var geometry: NotchGeometry
    private let panel: NotchPanel
    private let container: ShapeContainer
    private let host: NSHostingView<NotchRootView>
    private let session: SessionMonitor
    private let media: MediaMonitor
    private var cancellables = Set<AnyCancellable>()

    private var hovering = false
    private var collapseWork: DispatchWorkItem?
    private var hidden = false
    private var lastTrackedSize: CGSize = .zero

    init() {
        geometry = NotchGeometry.detect()
        let win = geometry.topCenteredFrame(for: geometry.windowSize)
        panel = NotchPanel(contentRect: win)
        session = SessionMonitor(state: state)
        media = MediaMonitor(state: state)

        container = ShapeContainer(frame: NSRect(origin: .zero, size: geometry.windowSize))
        host = NSHostingView(rootView: NotchRootView(state: state, geometry: geometry))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = []

        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        container.controller = self
        container.shapeRect = { [weak self] in self?.currentShapeRect() ?? .zero }

        host.rootView = makeRootView()
        observe()
    }

    private func makeRootView() -> NotchRootView {
        NotchRootView(state: state, geometry: geometry,
                      onClear: { [weak self] in self?.clearFiles() })
    }

    func start() {
        panel.orderFrontRegardless()
        session.start()
        media.start()
        updateVisibility()
    }

    // MARK: Shape geometry (shared by view + hit-testing)

    private func currentShapeSize() -> CGSize {
        geometry.shapeSize(presentation: state.presentation,
                           expanded: state.isExpanded,
                           dragOver: state.isDragOver)
    }

    /// Rect of the visible shape inside the window, in flipped view coords.
    private func currentShapeRect() -> CGRect {
        let s = currentShapeSize()
        let w = geometry.windowSize.width
        return CGRect(x: (w - s.width) / 2, y: 0, width: s.width, height: s.height)
    }

    // MARK: Hover

    func hover(_ inside: Bool) {
        hovering = inside
        inside ? expand() : scheduleCollapse()
    }

    // A smooth, symmetric ease-in-out spring — no snap, gentle on both ends.
    private var openAnim: Animation { .smooth(duration: 0.44) }
    private var closeAnim: Animation { .smooth(duration: 0.4) }

    private func expand() {
        collapseWork?.cancel()
        guard !state.isExpanded else { return }
        withAnimation(openAnim) { state.isExpanded = true }
        container.refreshTracking()
    }

    private func scheduleCollapse() {
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    private func collapse() {
        guard !hovering, !state.isDragOver, state.isExpanded else { return }
        withAnimation(closeAnim) { state.isExpanded = false }
        container.refreshTracking()
    }

    // MARK: Drag & drop

    func dragEntered() {
        collapseWork?.cancel()
        withAnimation(openAnim) { state.isDragOver = true }
        container.refreshTracking()
    }

    func dragExited() {
        withAnimation(closeAnim) { state.isDragOver = false }
        container.refreshTracking()
        if !hovering { scheduleCollapse() }
    }

    func dropped(_ urls: [URL]) {
        var files = state.droppedFiles
        for u in urls where !files.contains(u) { files.append(u) }
        withAnimation(openAnim) {
            state.droppedFiles = files
            state.isDragOver = false
        }
        container.refreshTracking()
    }

    func clearFiles() {
        withAnimation(closeAnim) {
            state.droppedFiles = []
            state.isExpanded = false
        }
        container.refreshTracking()
    }

    // MARK: Observation

    private func observe() {
        // Refresh the tracking area only when the shape size actually changes —
        // not on every token tick — so hovering never flickers.
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let size = self.currentShapeSize()
                    if size != self.lastTrackedSize {
                        self.lastTrackedSize = size
                        self.container.refreshTracking()
                    }
                }
            }
            .store(in: &cancellables)

        let ws = NSWorkspace.shared.notificationCenter
        ws.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .merge(with: ws.publisher(for: NSWorkspace.didActivateApplicationNotification))
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.screensChanged() }
            .store(in: &cancellables)
    }

    private func screensChanged() {
        geometry = NotchGeometry.detect()
        host.rootView = makeRootView()
        panel.setFrame(geometry.topCenteredFrame(for: geometry.windowSize), display: true)
        container.setFrameSize(geometry.windowSize)
        container.refreshTracking()
        updateVisibility()
    }

    /// Hide entirely when the notch is covered (a fullscreen app), since the
    /// menu-bar area isn't visible there anyway.
    private func updateVisibility() {
        let obscured = Fullscreen.notchObscured(on: geometry.screen)
        if obscured != hidden {
            hidden = obscured
            if obscured { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        }
    }
}

/// Detects whether a fullscreen window covers the notch display.
enum Fullscreen {
    static func notchObscured(on screen: NSScreen) -> Bool {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let sf = screen.frame
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = b["Width"], let h = b["Height"] else { continue }
            // A true fullscreen window spans the whole display (no menu bar gap).
            if w >= sf.width - 2 && h >= sf.height - 2 { return true }
        }
        return false
    }
}
