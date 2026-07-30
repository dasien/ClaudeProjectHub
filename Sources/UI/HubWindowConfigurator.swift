import AppKit
import SwiftUI

/// Configures the hub's NSWindow on first appear. Makes the dock area
/// a true "hole" for the docked foreign window beneath it: window is
/// transparent in the dock area (no opaque pixels there to cover the
/// docked window), and `HubMouseGate` toggles `ignoresMouseEvents`
/// based on cursor position so clicks pass through too.
///
/// Chrome (sidebar, tab bar, titlebar) keeps its solid look because
/// each has its own SwiftUI-side background or material.
struct HubWindowConfigurator: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowAccessView(onWindow: onWindow)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowAccessView: NSView {
    /// UserDefaults key under which we save the hub window's frame.
    /// Kept distinct from any autosave name SwiftUI/AppKit might
    /// assign internally to avoid stomping each other.
    private static let frameDefaultsKey = "ClaudeProjectHubMainWindowFrame"

    private let onWindow: (NSWindow) -> Void
    private var attached = false
    private var resizeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?

    init(onWindow: @escaping (NSWindow) -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !attached, let window else { return }
        attached = true
        // Window-wide visual config: transparent body so the dock area
        // can be a click-through hole. Drag only by the titlebar.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        // Persist the user's chosen window frame across launches.
        // We tried `setFrameAutosaveName` first; SwiftUI's WindowGroup
        // appears to override or compete with it. Direct UserDefaults
        // read on appear + write on resize/move is unambiguous.
        restoreSavedFrame(on: window)
        installFrameSaver(for: window)
        onWindow(window)
    }

    private func restoreSavedFrame(on window: NSWindow) {
        guard let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) else { return }
        let rect = NSRectFromString(saved)
        guard !rect.isEmpty else { return }
        // Guard against saved frames from a previous monitor layout
        // that no longer overlaps any visible screen.
        let onAnyScreen = NSScreen.screens.contains { $0.frame.intersects(rect) }
        guard onAnyScreen else { return }
        window.setFrame(rect, display: true)
    }

    private func installFrameSaver(for window: NSWindow) {
        // `[weak window]` breaks a retain cycle: the notification token
        // retains this block, the view retains the token, and the window
        // retains the view — so capturing `window` strongly kept the
        // whole graph alive and meant `deinit` (and therefore the
        // observer removal below) never ran. Leaked one window + view
        // hierarchy per hub-window close/reopen.
        let save: (Notification) -> Void = { [weak window] _ in
            guard let window else { return }
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameDefaultsKey)
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main,
            using: save
        )
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main,
            using: save
        )
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }
}
