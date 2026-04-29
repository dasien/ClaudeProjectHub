import AppKit
import SwiftUI

/// SwiftUI view modifier that publishes the modified view's frame in
/// CG/AX screen coordinates whenever it changes — including when the
/// containing NSWindow moves or resizes (events that don't change the
/// view's window-local frame and so wouldn't fire SwiftUI layout).
///
/// Coordinate chain: this view's bounds → window AppKit coords (via
/// `NSView.convert(_:to:nil)`) → screen AppKit coords (via
/// `NSWindow.convertToScreen`) → CG/AX coords (via the existing
/// `flippedToAXScreen` extension on CGRect).
///
/// Use as `.dockAreaFrame { rect in dockController.setDockRect(rect) }`.
struct DockAreaFrameTracker: ViewModifier {
    let onChange: (CGRect) -> Void

    func body(content: Content) -> some View {
        content.background(
            FrameReporterRepresentable(onChange: onChange)
        )
    }
}

extension View {
    /// Reports this view's CG/AX screen frame to `onChange` whenever
    /// the underlying NSView moves or resizes, or its containing
    /// window moves or resizes.
    func dockAreaFrame(_ onChange: @escaping (CGRect) -> Void) -> some View {
        modifier(DockAreaFrameTracker(onChange: onChange))
    }
}

// MARK: - NSView bridge

private struct FrameReporterRepresentable: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> FrameReporterView {
        let view = FrameReporterView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: FrameReporterView, context: Context) {
        nsView.onChange = onChange
    }
}

private final class FrameReporterView: NSView {
    var onChange: ((CGRect) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Returning nil tells AppKit "I'm not hittable" — mouse events
    /// fall through to whatever window is below in Z-order. With the
    /// hub window made transparent, that's the docked foreign window
    /// pinned to this same rectangle, so clicks land where the user
    /// expects.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installWindowObservers()
        publish()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        publish()
    }

    override var frame: NSRect {
        didSet { publish() }
    }

    override func layout() {
        super.layout()
        publish()
    }

    private func installWindowObservers() {
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowDidChange),
            name: NSWindow.didMoveNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowDidChange),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    @objc private func windowDidChange() {
        publish()
    }

    private func publish() {
        guard let window, !bounds.isEmpty else { return }
        // bounds → window AppKit coords → screen AppKit coords → CG/AX coords
        let inWindow = convert(bounds, to: nil)
        let inScreen = window.convertToScreen(inWindow)
        let inCG = inScreen.flippedToAXScreen
        onChange?(inCG)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
