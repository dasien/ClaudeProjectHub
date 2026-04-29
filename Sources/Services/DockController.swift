import AppKit
import ApplicationServices
import CoreGraphics

/// Owns the set of docked sessions and pins their host windows to the
/// hub's dock rectangle via AX. Drives layout updates, raises the
/// active tab, and listens for AX events on each docked window so it
/// can react to user-initiated moves/resizes (Phase 6 will use that
/// signal for undock-on-drag-out).
///
/// Coordinate space: `dockRect` is in CG/AX screen coordinates
/// (top-left origin, Y grows down) — the same space `AXSupport.setFrame`
/// expects.
@MainActor
final class DockController: ObservableObject {
    @Published private(set) var dockedSessionIDs: [Session.ID] = []
    @Published private(set) var activeSessionID: Session.ID?

    private var bindings: [Session.ID: AXUIElement] = [:]
    /// Cached at dock time so we can identify a window in destroy events
    /// (when the AXUIElement is no longer queryable).
    private var cgIDsBySession: [Session.ID: CGWindowID] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private let tracker = AXWriteTracker()
    /// Toggles ignoresMouseEvents on the hub window based on cursor
    /// position so clicks pass through to the docked foreign window
    /// when over the dock area.
    private let mouseGate = HubMouseGate()
    /// Debounce token for "settle then re-raise active window." Cancelled
    /// and rescheduled on every setDockRect during a drag — fires once
    /// the user stops moving/resizing.
    private var settleTask: Task<Void, Never>?
    /// Last frame we actually wrote per session. Used to skip redundant
    /// AX writes — a hub drag changes only origin (60Hz), so writing
    /// size every frame is pure waste.
    private var lastWrittenFrames: [Session.ID: CGRect] = [:]
    /// The foreign window's frame at the moment we docked it, in
    /// CG/AX coordinates. Restored on explicit undock (right-click,
    /// programmatic) so the released window goes back to a sensible
    /// place rather than staying stuck at the dock rect.
    private var preDockFrames: [Session.ID: CGRect] = [:]
    /// Per-session debounce token for "user dragged the docked
    /// window's titlebar — decide on settle whether to snap back or
    /// undock."
    private var dragSettleTasks: [Session.ID: Task<Void, Never>] = [:]
    /// Distance (px) the user has to drag a docked window's titlebar
    /// before we treat it as an undock-by-tearing-out gesture rather
    /// than a small nudge to be snapped back.
    private let undockThreshold: CGFloat = 30
    /// Token for the NSApplication.didBecomeActiveNotification observer.
    private var didBecomeActiveObserver: NSObjectProtocol?

    init() {
        // Re-raise the active docked window when the hub regains focus
        // after the user switched away to another app. Without this the
        // docked window can end up below other apps' windows in z-order
        // and the dock area shows whatever happens to be next-down
        // through our transparency.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.raiseActiveWithoutFocus()
            }
        }
    }

    deinit {
        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Set externally by `DockAreaFrameTracker` whenever the SwiftUI
    /// dock-area's screen frame changes (window move, window resize,
    /// sidebar drag).
    private(set) var dockRect: CGRect = .zero

    func setDockRect(_ rect: CGRect) {
        guard rect != dockRect else { return }
        dockRect = rect
        // Hot path during drag: only move the active (visible) tab.
        // Inactive tabs are hidden behind it at the same rect, so
        // their positions don't matter visually until they're raised.
        // The settle pass catches them up when the user stops moving.
        repositionActive()
        scheduleSettle()
        updateMouseGate()
    }

    /// Hands the hub's NSWindow to the mouse gate so it can toggle
    /// click-through. Called once on first appear by the SwiftUI
    /// HubWindowConfigurator.
    func attachHubWindow(_ window: NSWindow) {
        mouseGate.attach(to: window)
        updateMouseGate()
    }

    private func updateMouseGate() {
        mouseGate.setRect(dockRect, enabled: !dockedSessionIDs.isEmpty)
    }

    /// Adds a session's host window to the dock. Subscribes AX events
    /// for the window, writes its initial frame, raises it if it
    /// becomes the active tab.
    func dock(window: AXUIElement, sessionID: Session.ID) {
        guard !dockedSessionIDs.contains(sessionID) else { return }
        dockedSessionIDs.append(sessionID)
        bindings[sessionID] = window
        if let cgID = AXSupport.windowID(of: window) {
            cgIDsBySession[sessionID] = cgID
        }
        // Snapshot the window's pre-dock frame so we can restore it
        // if the user undocks via right-click. Done before the first
        // setFrame so we capture wherever the host app launched it.
        let initialFrame = AXSupport.frame(of: window)
        if !initialFrame.isEmpty {
            preDockFrames[sessionID] = initialFrame
        }
        // New docks become the active tab — matches the existing auto-
        // select-on-launch behavior in SessionStore. User can switch
        // away after the fact.
        activeSessionID = sessionID
        observe(window: window)
        repositionAll()
        raiseActive()
        updateMouseGate()
    }

    /// Stops pinning the session's host window. By default restores
    /// the foreign window to its pre-dock frame so the released
    /// window goes somewhere sensible. Pass `restoreFrame: false`
    /// when the user has already moved it themselves (drag-titlebar-
    /// out) and we don't want to fight their final position.
    func undock(sessionID: Session.ID, restoreFrame: Bool = true) {
        guard dockedSessionIDs.contains(sessionID) else { return }

        if restoreFrame,
           let element = bindings[sessionID],
           let preFrame = preDockFrames[sessionID],
           !preFrame.isEmpty {
            AXSupport.setFrame(preFrame, on: element)
        }

        dragSettleTasks[sessionID]?.cancel()
        dragSettleTasks.removeValue(forKey: sessionID)
        dockedSessionIDs.removeAll { $0 == sessionID }
        if activeSessionID == sessionID {
            activeSessionID = dockedSessionIDs.first
        }
        if let element = bindings.removeValue(forKey: sessionID) {
            unobserve(window: element)
        }
        cgIDsBySession.removeValue(forKey: sessionID)
        lastWrittenFrames.removeValue(forKey: sessionID)
        preDockFrames.removeValue(forKey: sessionID)
        if activeSessionID != nil { raiseActive() }
        updateMouseGate()
    }

    /// Switches the active tab. Raises the new active window via AX so
    /// it lands on top of any other docked windows in the same rect.
    /// Repositions the new active first because, with the active-only
    /// optimization, inactive tabs may have stale frames from before
    /// the last hub move/resize settled.
    func setActiveSessionID(_ id: Session.ID?) {
        guard activeSessionID != id else { return }
        activeSessionID = id
        repositionActive()
        raiseActive()
    }

    // MARK: - Layout

    /// Reposition only the active tab to the current dockRect. Hot
    /// path during hub drag — keeps lag O(1) regardless of how many
    /// sessions are docked.
    private func repositionActive() {
        guard let activeID = activeSessionID else { return }
        repositionOne(activeID)
    }

    /// Reposition every docked tab. Slow path; called from settle
    /// (when the hub stops moving) and from dock(). Inactive tabs
    /// catch up to the current dockRect here.
    private func repositionAll() {
        for id in dockedSessionIDs {
            repositionOne(id)
        }
    }

    private func repositionOne(_ id: Session.ID) {
        guard dockRect != .zero,
              let element = bindings[id],
              let cgID = cgIDsBySession[id] else { return }
        let last = lastWrittenFrames[id] ?? .zero
        // Skip writes for axes that haven't changed since the last
        // write for this session. During a hub drag origin changes
        // every frame but size doesn't — this halves the AX IPC.
        if dockRect.origin != last.origin {
            AXSupport.setPosition(dockRect.origin, on: element, windowID: cgID, tracker: tracker)
        }
        if dockRect.size != last.size {
            AXSupport.setSize(dockRect.size, on: element, windowID: cgID, tracker: tracker)
        }
        lastWrittenFrames[id] = dockRect
    }

    /// Activates the host app and raises the active window. Used when
    /// the user explicitly switches tabs or first docks a session —
    /// stealing focus is acceptable because the user just asked for
    /// it.
    private func raiseActive() {
        guard let id = activeSessionID,
              let element = bindings[id] else { return }
        if let pid = AXSupport.pid(of: element),
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        AXSupport.raise(element)
    }

    /// Raises the active window without activating its app. Used after
    /// a hub drag/resize settles — we want the docked window back on
    /// top of the dock area, but stealing focus from the hub mid-
    /// interaction would be jarring.
    private func raiseActiveWithoutFocus() {
        guard let id = activeSessionID,
              let element = bindings[id] else { return }
        AXSupport.raise(element)
    }

    /// Debounced "the user stopped moving the hub" handler. While
    /// they're actively dragging/resizing setDockRect fires repeatedly;
    /// we cancel and reschedule on every call. When the dust settles
    /// (~250ms with no further updates) we catch up the inactive tabs
    /// to the final rect (during the drag we only kept the active tab
    /// current to minimize AX IPC) and re-raise active in case it
    /// dropped behind anything.
    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.repositionAll()
            self.raiseActiveWithoutFocus()
        }
    }

    // MARK: - AX observation

    private func observe(window: AXUIElement) {
        guard let pid = AXSupport.pid(of: window) else { return }
        let observer: AXObserver
        if let existing = observers[pid] {
            observer = existing
        } else {
            guard let new = AXObserver(pid: pid, callback: { [weak self] event in
                self?.handle(event: event)
            }) else { return }
            observers[pid] = new
            observer = new
        }
        observer.subscribe(element: window, notifications: [
            AXNotification.moved,
            AXNotification.resized,
            AXNotification.destroyed
        ])
    }

    private func unobserve(window: AXUIElement) {
        guard let pid = AXSupport.pid(of: window),
              let observer = observers[pid] else { return }
        observer.unsubscribe(element: window, notifications: [
            AXNotification.moved,
            AXNotification.resized,
            AXNotification.destroyed
        ])
        // Don't drop the per-pid observer — sibling windows from the
        // same app may still be docked (e.g. two iTerm2 sessions).
    }

    private func handle(event: AXObserver.Event) {
        switch event.name {
        case AXNotification.moved, AXNotification.resized:
            handleGeometryEvent(event)
        case AXNotification.destroyed:
            handleDestroyEvent(event)
        default:
            break
        }
    }

    private func handleGeometryEvent(_ event: AXObserver.Event) {
        guard let cgID = AXSupport.windowID(of: event.element) else { return }
        let attribute = event.name == AXNotification.moved
            ? kAXPositionAttribute as String
            : kAXSizeAttribute as String
        if tracker.consume(window: cgID, attribute: attribute) {
            // Self-caused — ignore. This is the whole point of the tracker.
            return
        }
        // User-initiated drag/resize on a docked window. Schedule a
        // debounced evaluation — when activity stops we decide whether
        // to snap back (small nudge) or undock (real tear-out). AX
        // gives us no "drag ended" event so debounce is the proxy.
        guard let sessionID = sessionID(for: event.element) else { return }
        dragSettleTasks[sessionID]?.cancel()
        dragSettleTasks[sessionID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            self.dragSettleTasks.removeValue(forKey: sessionID)
            self.evaluateDraggedDocked(sessionID: sessionID)
        }
    }

    /// Decide what to do about a docked window the user just dragged
    /// or resized. If they pulled it far enough from the dock rect,
    /// or resized it to a different size, undock it. Otherwise snap
    /// back to the dock rect (small nudges shouldn't release).
    private func evaluateDraggedDocked(sessionID: Session.ID) {
        guard let element = bindings[sessionID] else { return }
        let current = AXSupport.frame(of: element)
        // Resize is decisive — the user wants a different size than
        // the dock allows. Undock without restoring (their size is
        // what they want).
        if current.size != dockRect.size {
            undock(sessionID: sessionID, restoreFrame: false)
            return
        }
        let dx = current.origin.x - dockRect.origin.x
        let dy = current.origin.y - dockRect.origin.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > undockThreshold {
            undock(sessionID: sessionID, restoreFrame: false)
        } else {
            // Small drag — snap back to the dock rect. The setFrame
            // is recorded with the tracker so the resulting AX event
            // doesn't loop us back here.
            repositionOne(sessionID)
        }
    }

    private func sessionID(for element: AXUIElement) -> Session.ID? {
        bindings.first(where: { _, candidate in
            CFEqual(candidate, element)
        })?.key
    }

    private func handleDestroyEvent(_ event: AXObserver.Event) {
        // The element is gone — can't query CGWindowID anymore. Find
        // the session by scanning the cached AXUIElements. CFEqual
        // works on AX refs even after destruction (compares identity).
        // Don't try to restore the frame on a destroyed window —
        // there's nothing to set.
        if let sessionID = sessionID(for: event.element) {
            undock(sessionID: sessionID, restoreFrame: false)
        }
    }
}
