import AppKit
import ApplicationServices
import CoreGraphics
import os.log

private let dockLog = Logger(subsystem: "com.bgentry.ClaudeProjectHub", category: "Dock")

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
    /// Host pids we've subscribed for app-level `focusedWindowChanged`
    /// (on the application element, not a window). Tracked so we
    /// subscribe once per pid rather than once per docked window.
    /// Drives "click a docked host window directly → hub selection
    /// follows" without moving any windows.
    private var appFocusSubscribedPIDs: Set<pid_t> = []
    /// Token for `NSWorkspace.didActivateApplicationNotification` —
    /// covers the cmd-tab-to-host case, where the focused window
    /// inside the host didn't change (so `focusedWindowChanged` won't
    /// fire) but the host app came forward.
    private var appActivatedObserver: NSObjectProtocol?
    private let tracker = AXWriteTracker()
    private lazy var animator = FrameAnimator(tracker: tracker)
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
    /// Tokens for the hub's app-level Cmd-H observers. App-hide is
    /// signaled by `NSApplication.willHide` / `didUnhide` rather than
    /// the window-level miniaturize notifications, so it needs its
    /// own pair of observers — installed in `init` since they're
    /// tied to NSApp, not to a specific window.
    private var hubWillHideObserver: NSObjectProtocol?
    private var hubDidUnhideObserver: NSObjectProtocol?
    /// Token for `NSApplication.didChangeScreenParametersNotification`.
    /// Fires on every display reconfig event (monitor connect/disconnect,
    /// resolution change, lid close/open with an external monitor
    /// attached). Multiple events fire for one user action — coalesced
    /// via `screenChangeSettleTask`.
    private var screenParametersObserver: NSObjectProtocol?
    /// Debounce token for screen-parameter changes — display reconfig
    /// posts several notifications in quick succession (monitor connect
    /// is typically 3-5 events), so we wait ~400ms after the last one
    /// before doing the re-pin pass.
    private var screenChangeSettleTask: Task<Void, Never>?
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
    /// Needed so a confirmed window destroy can release the session's
    /// WindowManager binding too — the AX element is dead, and the tab
    /// bar keys off `WindowManager.boundSessionIDs` to decide whether a
    /// session still has a window worth showing a tab for.
    private let windowManager: WindowManager
    /// Only used to turn a cached hostID into the host's
    /// `terminalScripting` capability for per-tab AppleScript. Resolved on
    /// demand rather than cached at dock time so a host edited in Settings
    /// (e.g. its bundle id corrected) takes effect without a re-dock.
    private let hostRegistry: HostRegistry

    init(store: SessionStore, windowManager: WindowManager, hostRegistry: HostRegistry) {
        self.store = store
        self.windowManager = windowManager
        self.hostRegistry = hostRegistry
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

        // Keep the hub's selection in sync when the user activates a
        // host app directly (cmd-tab, Dock icon, Mission Control)
        // rather than clicking in the hub. Selection-only: we never
        // move a window here — the user's already looking at what they
        // want. See handleExternalFocus.
        appActivatedObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in self.handleAppActivated(pid: pid) }
        }

        // Detect Cmd-H of the hub itself so docked windows hide
        // alongside the hub instead of orphaning on screen.
        // NSApplication.willHide/didUnhide are app-level (not
        // window-level) and only fire for THIS app's hide gestures,
        // so we don't need to filter by sender.
        let appCenter = NotificationCenter.default
        hubWillHideObserver = appCenter.addObserver(
            forName: NSApplication.willHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleHubWillMinimize() }
        }
        hubDidUnhideObserver = appCenter.addObserver(
            forName: NSApplication.didUnhideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleHubDidDeminiaturize() }
        }

        // Re-pin docked sessions after any display reconfiguration —
        // monitor (un)plug, resolution change, lid open/close while an
        // external monitor is attached. macOS migrates windows between
        // screens during these events; the foreign window's frame can
        // end up wherever macOS decided, not where our dock rect is
        // now. We coalesce the burst of notifications via
        // `scheduleScreenChangeSettle` and reposition on the trailing
        // edge.
        screenParametersObserver = appCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleScreenChangeSettle() }
        }
    }

    deinit {
        // `removeHubWindowObservers` is @MainActor-isolated (inherited
        // from this class) and can't be called from a nonisolated
        // deinit, so inline the cleanup. NotificationCenter is
        // thread-safe so direct removeObserver calls are fine here.
        let center = NotificationCenter.default
        if let observer = didBecomeActiveObserver {
            center.removeObserver(observer)
        }
        if let observer = hubWillMinimizeObserver {
            center.removeObserver(observer)
        }
        if let observer = hubDidDeminiaturizeObserver {
            center.removeObserver(observer)
        }
        if let observer = hubWillHideObserver {
            center.removeObserver(observer)
        }
        if let observer = hubDidUnhideObserver {
            center.removeObserver(observer)
        }
        if let observer = screenParametersObserver {
            center.removeObserver(observer)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let observer = appHiddenObserver {
            workspaceCenter.removeObserver(observer)
        }
        if let observer = appUnhiddenObserver {
            workspaceCenter.removeObserver(observer)
        }
        if let observer = appActivatedObserver {
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
        // If the hub window is being re-created (user closed and
        // reopened it), clean up stale observers from the previous
        // attachment before installing fresh ones.
        removeHubWindowObservers()

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

    private func removeHubWindowObservers() {
        let center = NotificationCenter.default
        if let observer = hubWillMinimizeObserver {
            center.removeObserver(observer)
            hubWillMinimizeObserver = nil
        }
        if let observer = hubDidDeminiaturizeObserver {
            center.removeObserver(observer)
            hubDidDeminiaturizeObserver = nil
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
        // Snap sibling docked sessions to the current dockRect (they
        // were already at it; this catches any drift). The newly-
        // added session gets an animated glide-in instead.
        for id in dockedSessionIDs where id != sessionID {
            repositionOne(id)
        }
        animateInto(sessionID: sessionID, from: initialFrame, element: window)
        raiseActive()
        updateMouseGate()
    }

    /// Animate the newly-docked window from its launch frame to the
    /// dock rect. Falls back to a snap (the existing `repositionOne`
    /// path) when we don't have a valid start frame or the dock rect
    /// hasn't been reported yet.
    private func animateInto(
        sessionID: Session.ID,
        from initialFrame: CGRect,
        element: AXUIElement
    ) {
        guard !initialFrame.isEmpty,
              !dockRect.isEmpty,
              let cgID = cgIDsBySession[sessionID] else {
            repositionOne(sessionID)
            return
        }
        animator.animate(
            sessionID: sessionID,
            element: element,
            windowID: cgID,
            from: initialFrame,
            to: dockRect
        )
        // Skip future redundant snap writes for this session — the
        // animator's last step lands on dockRect.
        lastWrittenFrames[sessionID] = dockRect
    }

    /// Stops pinning the session's host window. By default restores
    /// the foreign window to its pre-dock frame so the released
    /// window goes somewhere sensible. Pass `restoreFrame: false`
    /// when the user has already moved it themselves (drag-titlebar-
    /// out) and we don't want to fight their final position.
    /// - Parameter reason: why this undock is happening. Logged, because
    ///   an undock silently wipes the session's tabID/hostID/cgID and
    ///   that made "the hub can't switch tabs anymore" impossible to
    ///   trace — the undock is the damage, and several callers reach it
    ///   without logging anything themselves.
    func undock(sessionID: Session.ID, restoreFrame: Bool = true, reason: String = "unspecified") {
        guard dockedSessionIDs.contains(sessionID) else { return }
        dockLog.notice("undock \(sessionID, privacy: .public) — \(reason, privacy: .public)")

        // Cancel any in-flight dock-in animation for this session
        // before we start a new undock animation or release the
        // window — otherwise the animator would keep writing dock-
        // rect frames after we've handed control back.
        animator.cancel(sessionID: sessionID)

        // Snap to the pre-dock frame instead of animating: the
        // pre-dock position is often behind the hub (where the
        // host app spawned the window before docking), so an
        // undock animation would glide the window into a hidden
        // destination and read as "just disappeared" to the user.
        // Dock-in animation stays — that motion is into the
        // visible dock area.
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
        // The guard used to drop tabIDs silently, which is one of only
        // two ways a session can end up unable to switch tabs — say so.
        guard dockedSessionIDs.contains(sessionID) else {
            dockLog.notice("setTabID REJECTED for \(sessionID, privacy: .public) tty=\(tabID, privacy: .public) — session is not in dockedSessionIDs")
            return
        }
        dockLog.debug("setTabID accepted for \(sessionID, privacy: .public) tty=\(tabID, privacy: .public)")
        tabIDsBySession[sessionID] = tabID
    }

    /// Other docked sessions sharing this session's host window — i.e.
    /// its sibling tabs. Non-empty means closing the *window* would take
    /// those siblings down too.
    func siblingSessionIDs(of sessionID: Session.ID) -> [Session.ID] {
        guard let element = bindings[sessionID] else { return [] }
        return sessionIDs(for: element).filter { $0 != sessionID }
    }

    /// Closes only this session's tab inside its host window, leaving
    /// siblings running. Returns false when the host can't do it (no tab
    /// identity for the session, or no per-tab close in its AppleScript
    /// dictionary) so the caller can choose another strategy instead of
    /// closing the whole window.
    func closeHostTab(sessionID: Session.ID) -> Bool {
        guard let hostID = hostIDsBySession[sessionID] else { return false }
        guard let tabID = tabIDsBySession[sessionID] ?? deriveTabID(for: sessionID) else {
            dockLog.notice("closeHostTab: no tab identity for \(sessionID, privacy: .public) — cannot close just its tab")
            return false
        }
        let handled = HostTabSelector.closeTab(
            scripting: hostRegistry.host(forID: hostID)?.terminalScripting,
            tabIdentifier: tabID,
            windowID: cgIDsBySession[sessionID]
        )
        dockLog.notice("closeHostTab: host=\(hostID, privacy: .public) tty=\(tabID, privacy: .public) handled=\(handled, privacy: .public)")
        return handled
    }

    /// True iff this docked session has a known controlling-tty
    /// identifier for routing per-tab AppleScript switches.
    /// SessionLifecycleMonitor consults this each poll cycle and
    /// re-derives the tty if it's missing — catches the race where
    /// `ProcessTree.controllingTTY(of:)` returned nil at launch
    /// (before the kernel had assigned a tty to the new claude
    /// process) and the tab routing would otherwise be broken
    /// forever.
    func hasTabID(forSession sessionID: Session.ID) -> Bool {
        tabIDsBySession[sessionID] != nil
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
    /// (when the hub stops moving), from dock(), and after a debounced
    /// display reconfiguration event. Inactive tabs catch up to the
    /// current dockRect here.
    private func repositionAll() {
        for id in dockedSessionIDs {
            repositionOne(id)
        }
    }

    /// Debounce for `didChangeScreenParametersNotification`. Display
    /// reconfig fires several notifications for one user action — e.g.
    /// plugging in an external monitor typically posts 3-5 events
    /// across ~200ms as the OS goes through "begin configuration / set
    /// main display / end configuration." Coalesce them and only run
    /// the re-pin pass after the dust settles.
    private func scheduleScreenChangeSettle() {
        screenChangeSettleTask?.cancel()
        screenChangeSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.handleScreenParametersChanged()
        }
    }

    /// Re-pin every docked session to the current dock rect after a
    /// display reconfiguration. macOS migrates foreign windows between
    /// screens on monitor (un)plug and lid open/close-with-external;
    /// without this pass they end up wherever the OS put them rather
    /// than back inside the hub's dock area. Dangling AX elements —
    /// which can briefly appear during the reconfig — get undocked,
    /// matching the destroy-event cleanup path.
    private func handleScreenParametersChanged() {
        guard !dockedSessionIDs.isEmpty else { return }
        dockLog.notice("Display configuration changed — validating + re-pinning \(self.dockedSessionIDs.count, privacy: .public) docked session(s)")
        // Collect dangling first so we don't mutate dockedSessionIDs
        // while iterating.
        var dangling: [Session.ID] = []
        for id in dockedSessionIDs {
            guard let element = bindings[id] else { continue }
            if !AXSupport.elementIsLive(element) {
                dangling.append(id)
            }
        }
        for id in dangling {
            undock(sessionID: id, restoreFrame: false, reason: "AX element dangling after display reconfiguration")
        }
        repositionAll()
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
        if AXSupport.raise(element) {
            selectActiveTab()
        } else {
            // Probe failed → element is dangling. Same cleanup path
            // the AX destroy-notification handler uses; the binding's
            // gone for the same reason, just detected at use time
            // instead of via the AX observer.
            undock(sessionID: id, restoreFrame: false, reason: "raise failed, element dangling (raiseActive)")
        }
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
        if AXSupport.raise(element) {
            if syncTab { selectActiveTab() }
        } else {
            // Dangling element — same cleanup as the destroy handler.
            undock(sessionID: id, restoreFrame: false, reason: "raise failed, element dangling (raiseActiveWithoutFocus)")
        }
    }

    /// Asks the host to switch its internal tab to match the active
    /// session. No-op for hosts without tabs or without a tab ID.
    /// Doesn't activate the host app — `tell window to select tab`
    /// just changes the host's current tab without front-stealing.
    private func selectActiveTab() {
        guard let id = activeSessionID else { return }
        // All three of these used to fail silently, which made "the hub
        // shows the wrong tab" impossible to diagnose from outside. A
        // missing hostID or tabID means no tab switch happens at all,
        // so say which one is absent.
        guard let hostID = hostIDsBySession[id] else {
            dockLog.notice("selectActiveTab: no hostID cached for active session \(id, privacy: .public) — cannot switch tab")
            return
        }
        guard let tabID = tabIDsBySession[id] ?? deriveTabID(for: id) else {
            // Two very different reasons, worth different log levels.
            // No pid yet is the normal state in the first moments of a
            // launch or resume — `dock()` raises before
            // `discoverAndBind` has identified the claude process, and
            // the host has just focused that tab itself anyway, so
            // there's nothing to correct. A session with a live pid but
            // no resolvable tty is genuinely unexpected.
            if let pid = store.sessions.first(where: { $0.id == id })?.pid {
                dockLog.notice("selectActiveTab: session \(id, privacy: .public) has pid \(pid, privacy: .public) but no resolvable tty — cannot switch tab")
            } else {
                dockLog.debug("selectActiveTab: session \(id, privacy: .public) has no pid yet (launch in flight) — nothing to switch")
            }
            return
        }
        // Pass the cached CGWindowID so the script can address the
        // window directly instead of walking every one of the host's
        // windows. Nil is handled (falls back to the walk).
        let windowID = cgIDsBySession[id]
        dockLog.debug("selectActiveTab: host=\(hostID, privacy: .public) tty=\(tabID, privacy: .public) windowID=\(windowID.map(String.init) ?? "nil", privacy: .public)")
        HostTabSelector.selectTab(
            scripting: hostRegistry.host(forID: hostID)?.terminalScripting,
            tabIdentifier: tabID,
            windowID: windowID
        )
    }

    /// Last-resort tabID lookup: read the controlling tty straight from
    /// the session's claude pid, and cache it.
    ///
    /// The tabID is normally captured by the launch flow, but only after
    /// `waitForNewClaudePID` identifies the pid (up to 8s of polling) and
    /// the kernel has assigned a tty. Clicking a tab inside that window
    /// found no tabID and silently did nothing — reproducible as "the
    /// first click on a just-created session doesn't switch the host
    /// tab." Deriving on demand removes the dependency on capture
    /// timing entirely; the launch-path capture and the lifecycle
    /// self-heal are now optimisations rather than prerequisites.
    ///
    /// Cheap enough for the click path: one `sysctl` via `ProcessTree`,
    /// and only when the cache misses.
    private func deriveTabID(for sessionID: Session.ID) -> String? {
        guard let pid = store.sessions.first(where: { $0.id == sessionID })?.pid,
              let tty = ProcessTree.controllingTTY(of: pid) else { return nil }
        tabIDsBySession[sessionID] = tty
        dockLog.notice("Derived missing tabID on demand for \(sessionID, privacy: .public) — tty=\(tty, privacy: .public) from pid \(pid, privacy: .public)")
        return tty
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
        // Subscribe focusedWindowChanged once per host pid, on the
        // application element (it's an app-level notification, not a
        // window one). Fires when the user clicks a different window
        // of this host — we use it to follow the selection.
        if !appFocusSubscribedPIDs.contains(pid) {
            observer.subscribe(element: AXSupport.appElement(for: pid), notifications: [
                AXNotification.focusedWindowChanged
            ])
            appFocusSubscribedPIDs.insert(pid)
        }
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
        case AXNotification.focusedWindowChanged:
            // event.element is the application element the notification
            // was registered on; its current focused window is the one
            // the user just brought forward.
            if let focused = AXSupport.focusedWindow(ofApplication: event.element) {
                handleExternalFocus(window: focused)
            }
        default:
            break
        }
    }

    /// User activated a host app directly (cmd-tab / Dock / Mission
    /// Control). If it hosts docked sessions, follow the selection to
    /// its focused window. No-op when the app isn't one we're docking.
    private func handleAppActivated(pid: pid_t) {
        guard observers[pid] != nil else { return }
        guard let focused = AXSupport.focusedWindow(ofApplication: AXSupport.appElement(for: pid)) else { return }
        handleExternalFocus(window: focused)
    }

    /// The user brought a foreign host window to the front outside the
    /// hub (clicked it, cmd-tabbed to it). If it maps to a docked
    /// session, sync the hub's selection to match — *without* moving
    /// any window. See `syncSelection`.
    ///
    /// Must use the plural lookup: for tab-sharing hosts every tab in a
    /// window is the same AXUIElement, so the singular `sessionID(for:)`
    /// returns an arbitrary sibling from dictionary order. That produced
    /// a real desync — clicking tab A fires `focusedWindowChanged` from
    /// our own raise, the lookup answers B, and the hub selects B while
    /// the terminal is showing A (and `MainView.onChange` early-returns,
    /// so nothing corrects it). If the active session is among the
    /// window's sessions we're already correct and do nothing; AX can't
    /// tell us *which tab* has focus, so we don't guess between the
    /// remaining siblings.
    private func handleExternalFocus(window: AXUIElement) {
        let candidates = sessionIDs(for: window)
        guard !candidates.isEmpty else { return }
        if let active = activeSessionID, candidates.contains(active) { return }
        guard candidates.count == 1, let only = candidates.first else { return }
        syncSelection(to: only)
    }

    /// Selection-only sync used by the external-focus paths. Sets the
    /// dock's `activeSessionID` *first*, then mirrors it into
    /// `store.selectedSessionID`. Ordering matters: MainView observes
    /// selectedSessionID and calls back into `setActiveSessionID`,
    /// which early-returns when the id is already active — so pre-
    /// setting activeSessionID means that callback is a no-op and no
    /// raise/reposition happens. That's what keeps this "selection
    /// only": the user already has the window they want up front; we
    /// just make the sidebar and tab bar agree with reality.
    ///
    /// The `activeSessionID != sessionID` guard is also the loop
    /// breaker: our own raises fire focusedWindowChanged for the
    /// already-active session, and this bails before touching anything.
    private func syncSelection(to sessionID: Session.ID) {
        guard activeSessionID != sessionID else { return }
        guard !minimizedSessionIDs.contains(sessionID) else { return }
        activeSessionID = sessionID
        store.selectedSessionID = sessionID
    }

    /// Minimizing a window minimizes *every* session in it, so mark all
    /// of them. With the singular lookup only one sibling got marked,
    /// and the consequences were both user-visible: if the unmarked
    /// sibling was active, the next hub activation's raise un-hid the
    /// window the user had just minimized (the exact hazard the Cmd-M/
    /// Cmd-H lesson in CLAUDE.md documents); and `visibleDockedSessionIDs`
    /// still contained it, so the mouse gate kept click-through enabled
    /// over a dock rect with no window behind it.
    private func handleMiniaturizedEvent(_ event: AXObserver.Event) {
        let affected = sessionIDs(for: event.element)
        guard !affected.isEmpty else { return }
        minimizedSessionIDs.formUnion(affected)
        // Skip auto-promote when the minimize is part of a hub-driven
        // batch — every visible session is going down together, no
        // sibling to promote to. Promoting to a sibling of the *same*
        // window would also be pointless: it's equally minimized.
        if let active = activeSessionID,
           affected.contains(active),
           !hubMinimizedSessionIDs.contains(active) {
            promoteActiveAwayFromMinimized()
        }
        updateMouseGate()
    }

    private func handleDeminiaturizedEvent(_ event: AXObserver.Event) {
        let affected = sessionIDs(for: event.element)
        guard !affected.isEmpty else { return }
        minimizedSessionIDs.subtract(affected)
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
        // The user dragged a *window*, so the verdict applies to every
        // session sharing it (tab siblings). Undocking only the one
        // session the event happened to resolve to left the survivor
        // docked, and its next `repositionAll` dragged the window right
        // back into the dock rect — so a tear-out of a 2-tab window
        // appeared to snap back.
        let affected = sessionIDs(for: element)
        let dx = current.origin.x - dockRect.origin.x
        let dy = current.origin.y - dockRect.origin.y
        let distance = (dx * dx + dy * dy).squareRoot()

        // Only a *move* releases the dock. A resize never does.
        //
        // This used to undock on any size change ("the user wants a
        // different size than the dock allows"), which broke as soon as
        // a host resized itself: adding a second tab makes iTerm2 grow
        // the window by its tab-bar height — measured at 35px here, and
        // it varies with theme and host — so creating a sibling session
        // tore the window out of the dock and took both sessions'
        // tabIDs with it. Thresholding the delta just moved the magic
        // number around; the tab bar is bigger than any threshold small
        // enough to still catch a deliberate resize.
        //
        // A docked window is pinned, so its size belongs to the dock:
        // snap it back and absorb host chrome changes of any size.
        // Verified iTerm2 accepts being held at the dock height with
        // two tabs open (it just gives the content area 35px less) and
        // does not reassert, so this doesn't become a tug-of-war. The
        // user can still tear out by dragging the titlebar, or undock
        // explicitly from the sidebar's right-click menu.
        if distance > undockThreshold {
            dockLog.notice("evaluateDraggedDocked: dragged \(Int(distance), privacy: .public)px > \(Int(self.undockThreshold), privacy: .public)px — undocking \(affected.count, privacy: .public) session(s)")
            for id in affected { undock(sessionID: id, restoreFrame: false, reason: "user dragged window out of dock rect") }
        } else {
            // Small drag — snap back to the dock rect. One write covers
            // every sibling; they're the same window. The setFrame is
            // recorded with the tracker so the resulting AX event
            // doesn't loop us back here.
            repositionOne(sessionID)
        }
    }

    private func sessionID(for element: AXUIElement) -> Session.ID? {
        bindings.first(where: { _, candidate in
            CFEqual(candidate, element)
        })?.key
    }

    /// Every session bound to this AX element. Multiple matches happen
    /// when sibling sessions share one host window — most commonly
    /// iTerm2/Terminal tabs, where every tab in one window shares the
    /// same AXUIElement. Single-match callers (geometry/minimize) can
    /// stay on `sessionID(for:)`; `handleDestroyEvent` must use this
    /// plural form, otherwise only one of the tab-sharing siblings gets
    /// undocked when the shared window dies and the survivor lingers
    /// in `dockedSessionIDs` as a zombie with a dangling AX binding.
    private func sessionIDs(for element: AXUIElement) -> [Session.ID] {
        bindings.compactMap { id, candidate in
            CFEqual(candidate, element) ? id : nil
        }
    }

    private func handleDestroyEvent(_ event: AXObserver.Event) {
        // The AXUIElement is reported destroyed — can't query CGWindowID
        // from the ref anymore. Find every session bound to this element
        // (CFEqual works on AX refs even after destruction — it's an
        // identity compare). N>1 happens for tab-sharing siblings.
        let affected = sessionIDs(for: event.element)
        guard !affected.isEmpty else { return }

        // macOS fires spurious destroy events during sleep/wake, display
        // reconfiguration, screen lock, and other transients — the AX
        // server reissues window refs and the old ones get reported as
        // destroyed before the new ones settle. Defer the undock and
        // re-validate via CGWindowListCopyWindowInfo against the cached
        // CGWindowID: if WindowServer still has the window, the destroy
        // was spurious and we leave the bindings alone. If it's actually
        // gone, follow through for every affected session. 500ms is well
        // past any sleep/wake re-registration flutter without being
        // noticeable for genuine close events.
        let cachedID = affected.compactMap { cgIDsBySession[$0] }.first
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self else { return }
            if let cachedID, Self.windowExists(cgID: cachedID) {
                dockLog.notice("Suppressed spurious destroy event for cgID \(cachedID, privacy: .public) — window still in WindowServer's list")
                return
            }
            dockLog.notice("Destroy confirmed — undocking \(affected.count, privacy: .public) session(s) bound to the destroyed window")
            for id in affected {
                self.undock(sessionID: id, restoreFrame: false, reason: "host window destroyed")
                // Release the WindowManager binding too. The element is
                // dead, so holding it only produces failed raises — and
                // the tab bar keys off boundSessionIDs to drop the tab
                // for a session that no longer has a window, rather than
                // waiting for the claude process to exit (which can lag
                // the window close by several seconds).
                self.windowManager.unbind(id)
            }
        }
    }

    /// Asks WindowServer (not the AX layer) whether a window with this
    /// CGWindowID currently exists. Used to suppress spurious AX
    /// destroy notifications. Authoritative source is WindowServer's
    /// own window list — AX is the layer that goes briefly confused
    /// during sleep/wake; CGWindowListCopyWindowInfo is not.
    private static func windowExists(cgID: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            cgID
        ) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == cgID }
    }
}
