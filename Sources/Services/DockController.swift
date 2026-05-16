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
    /// HostID per docked session — needed to dispatch host-specific
    /// tab-selection AppleScript when raising. Without it, two
    /// sibling iTerm2 tabs both AXRaise the same window without
    /// switching tabs.
    private var hostIDsBySession: [Session.ID: String] = [:]
    /// Tab identifier (tty for terminal hosts) per docked session.
    /// Optional — hosts without tabs (VSCode, Xcode) leave this nil.
    private var tabIDsBySession: [Session.ID: String] = [:]
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
    /// Tokens for NSWorkspace app-hide/unhide observers — used to
    /// detect Cmd-H on a docked foreign app, which doesn't fire any
    /// AX notification we can observe per-window.
    private var appHiddenObserver: NSObjectProtocol?
    private var appUnhiddenObserver: NSObjectProtocol?
    /// Tokens for the hub's own minimize/deminiaturize observers.
    /// Installed in `attachHubWindow`.
    private var hubWillMinimizeObserver: NSObjectProtocol?
    private var hubDidDeminiaturizeObserver: NSObjectProtocol?
    /// Sessions the hub itself minimized as part of a hub-window
    /// minimize. Used so a hub-restore only un-minimizes the ones
    /// the *hub* hid, not sessions the user had individually
    /// minimized before the hub went down. Also used by the
    /// miniaturize event handler to skip auto-promote when the
    /// minimize is part of a hub-driven batch (everyone's going
    /// down at once, there's nothing to promote to).
    private var hubMinimizedSessionIDs: Set<Session.ID> = []
    /// Sessions whose docked foreign window is currently minimized
    /// (yellow button / Cmd-M) or whose foreign app is currently
    /// hidden (Cmd-H). Tracking these so the raise + snap-back paths
    /// don't fight the user's "make this disappear" gesture — without
    /// the guard, hub-becomes-active would AX-raise the window and
    /// effectively un-hide it. Sessions stay in `dockedSessionIDs`
    /// while minimized; they're tracked, just not currently visible.
    /// Published so the sidebar and tab bar can mute their rows for
    /// minimized sessions.
    @Published private(set) var minimizedSessionIDs: Set<Session.ID> = []

    /// Docked sessions whose foreign window is currently visible —
    /// i.e. neither minimized (Cmd-M) nor app-hidden (Cmd-H). Used by
    /// the TabbedHostArea placeholder logic (a transparent dock area
    /// with all sessions hidden looks broken) and by updateMouseGate
    /// (click-through should only be on when there's a real foreign
    /// window underneath).
    var visibleDockedSessionIDs: [Session.ID] {
        dockedSessionIDs.filter { !minimizedSessionIDs.contains($0) }
    }
    /// The store is read+written for active-session promotion: when
    /// the user minimizes the active docked window, we promote a
    /// sibling and need to propagate that to the SwiftUI selection so
    /// the sidebar/tabs follow. Injected at app launch.
    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
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
                // syncTab: false because the user may have switched
                // iTerm2/Terminal tabs themselves while the hub was
                // backgrounded. Forcing the host's tab back to the
                // hub's activeSessionID would undo that manual switch
                // every time they cmd-tab back to the hub.
                self?.raiseActiveWithoutFocus(syncTab: false)
            }
        }

        // Detect Cmd-H of foreign apps so we can stop re-raising their
        // docked windows. NSWorkspace fires app-hide/unhide at the
        // application level — there's no per-window AX event for
        // Cmd-H (kAXWindowMiniaturized covers Cmd-M / yellow button
        // only).
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        appHiddenObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in self.handleAppHidden(pid: pid) }
        }
        appUnhiddenObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in self.handleAppUnhidden(pid: pid) }
        }
    }

    deinit {
        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = hubWillMinimizeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = hubDidDeminiaturizeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let observer = appHiddenObserver {
            workspaceCenter.removeObserver(observer)
        }
        if let observer = appUnhiddenObserver {
            workspaceCenter.removeObserver(observer)
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
    /// HubWindowConfigurator. Also installs the hub-minimize /
    /// hub-restore observers so docked foreign windows follow the
    /// hub up and down (otherwise they'd orphan as top-level
    /// windows above the Dock when the hub minimizes).
    func attachHubWindow(_ window: NSWindow) {
        mouseGate.attach(to: window)
        updateMouseGate()

        let center = NotificationCenter.default
        hubWillMinimizeObserver = center.addObserver(
            forName: NSWindow.willMiniaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleHubWillMinimize() }
        }
        hubDidDeminiaturizeObserver = center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleHubDidDeminiaturize() }
        }
    }

    /// Hub is about to minimize — minimize every currently-visible
    /// docked window so they don't orphan as top-level windows
    /// above the Dock. Remember which sessions we minimized so the
    /// matching restore un-minimizes only those (sessions the user
    /// had individually hidden before stay hidden through the
    /// round-trip).
    private func handleHubWillMinimize() {
        let toMinimize = visibleDockedSessionIDs
        hubMinimizedSessionIDs.formUnion(toMinimize)
        for sessionID in toMinimize {
            guard let element = bindings[sessionID] else { continue }
            AXSupport.setMinimized(true, on: element)
            // AX kAXWindowMiniaturizedNotification will fire and
            // update minimizedSessionIDs via the existing handler;
            // that handler checks hubMinimizedSessionIDs to skip
            // the auto-promote (everyone's going down).
        }
    }

    /// Hub just deminiaturized — un-minimize only the sessions we
    /// took down as part of `handleHubWillMinimize`. Leave alone
    /// any session the user individually minimized while the hub
    /// was down or before.
    private func handleHubDidDeminiaturize() {
        for sessionID in hubMinimizedSessionIDs {
            guard let element = bindings[sessionID] else { continue }
            AXSupport.setMinimized(false, on: element)
        }
        hubMinimizedSessionIDs.removeAll()
    }

    private func updateMouseGate() {
        // Click-through is only safe when a real foreign window sits
        // under the dock area. With all docked sessions minimized,
        // the placeholder must absorb clicks instead — otherwise they
        // leak through to the desktop.
        mouseGate.setRect(dockRect, enabled: !visibleDockedSessionIDs.isEmpty)
    }

    /// Adds a session's host window to the dock. Subscribes AX events
    /// for the window, writes its initial frame, raises it if it
    /// becomes the active tab.
    ///
    /// `hostID` and `tabID` (when known) let us switch the host's
    /// internal tab on raise — necessary for hosts where multiple
    /// docked sessions share one window (e.g. two iTerm2 tabs).
    func dock(
        window: AXUIElement,
        sessionID: Session.ID,
        hostID: String,
        tabID: String? = nil
    ) {
        guard !dockedSessionIDs.contains(sessionID) else { return }
        dockedSessionIDs.append(sessionID)
        bindings[sessionID] = window
        if let cgID = AXSupport.windowID(of: window) {
            cgIDsBySession[sessionID] = cgID
        }
        hostIDsBySession[sessionID] = hostID
        if let tabID {
            tabIDsBySession[sessionID] = tabID
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
        minimizedSessionIDs.remove(sessionID)
        hubMinimizedSessionIDs.remove(sessionID)
        if activeSessionID == sessionID {
            activeSessionID = dockedSessionIDs.first
        }
        if let element = bindings.removeValue(forKey: sessionID) {
            unobserve(window: element)
        }
        cgIDsBySession.removeValue(forKey: sessionID)
        hostIDsBySession.removeValue(forKey: sessionID)
        tabIDsBySession.removeValue(forKey: sessionID)
        lastWrittenFrames.removeValue(forKey: sessionID)
        preDockFrames.removeValue(forKey: sessionID)
        // Don't activate the new active's host app — the user just
        // closed something; pulling focus over to a sibling foreign
        // window would be jarring. AX raise alone keeps the right
        // window visible through the transparent dock area.
        if activeSessionID != nil { raiseActiveWithoutFocus() }
        updateMouseGate()
    }

    /// Sets the tab identifier for an already-docked session. Used by
    /// the launch flow once we know the new claude process's pid (and
    /// can derive its controlling tty), since dock() runs before that
    /// info is available.
    func setTabID(sessionID: Session.ID, tabID: String) {
        guard dockedSessionIDs.contains(sessionID) else { return }
        tabIDsBySession[sessionID] = tabID
    }

    /// Switches the active tab. Raises the new active window via AX
    /// (without activating the host app) so it lands on top of any
    /// other docked windows in the same rect. Repositions the new
    /// active first because, with the active-only optimization,
    /// inactive tabs may have stale frames from before the last hub
    /// move/resize settled.
    ///
    /// Doesn't activate the host app on purpose: tab/sidebar clicks
    /// are "browse" gestures — the user is interacting with the hub.
    /// Activation steals keyboard focus from the hub, which causes
    /// the perceived flicker on every sidebar click. If the user
    /// wants to interact with the docked window directly, they click
    /// inside the dock area (click-through to the foreign window
    /// activates it via the OS).
    func setActiveSessionID(_ id: Session.ID?) {
        let alreadyActive = activeSessionID == id
        let needsRestore = id.map { minimizedSessionIDs.contains($0) } ?? false
        // Normally clicking the already-active session is a no-op. But
        // if the active session is currently minimized/hidden, the
        // click is the user's "bring it back" gesture and we have to
        // run the restore path.
        guard !alreadyActive || needsRestore else { return }

        if let id, needsRestore {
            restore(sessionID: id)
        }
        activeSessionID = id
        repositionActive()
        raiseActiveWithoutFocus()
    }

    /// Reverses a Cmd-M minimize and/or a Cmd-H app-hide for the
    /// given docked session. Called when the user explicitly reselects
    /// a minimized session in the hub. Idempotent — both writes are
    /// no-ops if the corresponding state isn't set.
    private func restore(sessionID: Session.ID) {
        // Clear the flag eagerly so the raise that follows isn't
        // blocked by our own guard. The AX deminiaturize event and
        // NSWorkspace unhide event will arrive a beat later and find
        // the set already clean — both removers are idempotent.
        minimizedSessionIDs.remove(sessionID)
        updateMouseGate()
        guard let element = bindings[sessionID] else { return }
        AXSupport.setMinimized(false, on: element)
        if let pid = AXSupport.pid(of: element),
           let app = NSRunningApplication(processIdentifier: pid),
           app.isHidden {
            app.unhide()
        }
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
        // Don't raise a session whose window the user just hid or
        // minimized — AXSupport.raise would un-hide the foreign app
        // (setting AXMain / AXFocused on a hidden window deminiaturizes
        // it on most macOS versions). Phase 8 step 3 will auto-promote
        // a sibling so the tab bar stays coherent; for now we just
        // respect the gesture.
        guard !minimizedSessionIDs.contains(id) else { return }
        if let pid = AXSupport.pid(of: element),
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        AXSupport.raise(element)
        selectActiveTab()
    }

    /// Raises the active window without activating its app. Used after
    /// a hub drag/resize settles — we want the docked window back on
    /// top of the dock area, but stealing focus from the hub mid-
    /// interaction would be jarring.
    ///
    /// `syncTab` controls whether to also tell the host (iTerm2,
    /// Terminal) to switch its internal tab to match `activeSessionID`.
    /// True for paths where the active session genuinely changed
    /// (settle, undock); false for paths where we just want to bring
    /// the same window back on top without disturbing the user's own
    /// tab choice (focus return after cmd-tab away).
    private func raiseActiveWithoutFocus(syncTab: Bool = true) {
        guard let id = activeSessionID,
              let element = bindings[id] else { return }
        // See raiseActive for the rationale — minimized sessions get
        // skipped so we don't un-hide the user's hidden window.
        guard !minimizedSessionIDs.contains(id) else { return }
        AXSupport.raise(element)
        if syncTab { selectActiveTab() }
    }

    /// Asks the host to switch its internal tab to match the active
    /// session. No-op for hosts without tabs or without a tab ID.
    /// Doesn't activate the host app — `tell window to select tab`
    /// just changes the host's current tab without front-stealing.
    private func selectActiveTab() {
        guard let id = activeSessionID,
              let hostID = hostIDsBySession[id],
              let tabID = tabIDsBySession[id] else { return }
        HostTabSelector.selectTab(hostID: hostID, tabIdentifier: tabID)
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
            AXNotification.destroyed,
            AXNotification.miniaturized,
            AXNotification.deminiaturized
        ])
    }

    private func unobserve(window: AXUIElement) {
        guard let pid = AXSupport.pid(of: window),
              let observer = observers[pid] else { return }
        observer.unsubscribe(element: window, notifications: [
            AXNotification.moved,
            AXNotification.resized,
            AXNotification.destroyed,
            AXNotification.miniaturized,
            AXNotification.deminiaturized
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
        case AXNotification.miniaturized:
            handleMiniaturizedEvent(event)
        case AXNotification.deminiaturized:
            handleDeminiaturizedEvent(event)
        default:
            break
        }
    }

    private func handleMiniaturizedEvent(_ event: AXObserver.Event) {
        guard let sessionID = sessionID(for: event.element) else { return }
        minimizedSessionIDs.insert(sessionID)
        // Skip auto-promote when the minimize is part of a hub-driven
        // batch — every visible session is going down together, no
        // sibling to promote to.
        if !hubMinimizedSessionIDs.contains(sessionID),
           activeSessionID == sessionID {
            promoteActiveAwayFromMinimized()
        }
        updateMouseGate()
    }

    private func handleDeminiaturizedEvent(_ event: AXObserver.Event) {
        guard let sessionID = sessionID(for: event.element) else { return }
        minimizedSessionIDs.remove(sessionID)
        updateMouseGate()
    }

    /// Cmd-H hid the foreign app — mark every docked session that
    /// belongs to it as "currently not visible" so we stop trying to
    /// raise its window on hub-becomes-active. The session record
    /// stays alive; we just respect the user's hide gesture.
    private func handleAppHidden(pid: pid_t) {
        var activeWasHidden = false
        for sessionID in dockedSessionIDs {
            guard let element = bindings[sessionID],
                  AXSupport.pid(of: element) == pid else { continue }
            minimizedSessionIDs.insert(sessionID)
            if activeSessionID == sessionID {
                activeWasHidden = true
            }
        }
        if activeWasHidden {
            promoteActiveAwayFromMinimized()
        }
        updateMouseGate()
    }

    private func handleAppUnhidden(pid: pid_t) {
        for sessionID in dockedSessionIDs {
            guard let element = bindings[sessionID],
                  AXSupport.pid(of: element) == pid else { continue }
            minimizedSessionIDs.remove(sessionID)
        }
        updateMouseGate()
    }

    /// Pick the most-recently-docked non-minimized session and make
    /// it the active tab, so the dock area shows a real window rather
    /// than an empty hole when the active session is hidden. If all
    /// docked sessions are now minimized, leave activeSessionID alone
    /// — the tab bar continues to indicate the user's last choice
    /// (visually muted in a future step), the dock area is empty, and
    /// re-selecting that session restores it.
    private func promoteActiveAwayFromMinimized() {
        let candidates = dockedSessionIDs.filter { !minimizedSessionIDs.contains($0) }
        guard let newActive = candidates.last else { return }
        activeSessionID = newActive
        // Defer the SwiftUI selection write so we don't publish from
        // inside a Combine sink that itself fires off AX events on the
        // main run loop — without the hop, SwiftUI warns about
        // "Publishing changes from within view updates."
        Task { @MainActor [weak self] in
            self?.store.selectedSessionID = newActive
        }
        repositionActive()
        raiseActiveWithoutFocus()
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
        // Ignore geometry events for minimized/hidden sessions —
        // those are macOS animating the window to/from the Dock
        // (Cmd-M), not the user dragging it out. Without this guard
        // the snap-back-vs-undock evaluator would see a huge distance
        // delta and undock the session.
        guard !minimizedSessionIDs.contains(sessionID) else { return }
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
