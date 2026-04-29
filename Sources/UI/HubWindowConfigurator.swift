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
    private let onWindow: (NSWindow) -> Void
    private var attached = false

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
        onWindow(window)
    }
}
