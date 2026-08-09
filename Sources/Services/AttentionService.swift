import AppKit
import Combine
import Foundation
import OSLog
import UserNotifications

private let notifyLog = Logger(subsystem: "com.bgentry.ClaudeProjectHub", category: "Notify")

/// Tracks which docked sessions need the user's attention — i.e.
/// transitioned from `.working` to `.idle` (claude is waiting for
/// input). Drives two surfaces:
///
/// 1. **In-app indicator** via `needsAttention` (the sidebar's
///    `SessionRow` reads this and pulses the status dot).
/// 2. **Notification Center banner** posted via the
///    `UserNotifications` framework, gated on the user's settings
///    toggle and on the hub not being the foreground app (default
///    macOS behavior — when hub is active the user can already see
///    the in-app indicator).
///
/// Cleared when:
/// - User selects the session in the sidebar (via `store.selectedSessionID`)
/// - Session transitions back to `.working` (or `.closed`)
/// - User clicks the notification banner
/// - The host app of the currently-selected session becomes active —
///   covers "user clicked inside the docked foreign window," which is
///   the natural acknowledgement gesture when the badged session is
///   already the selected one (the selectedSessionID publisher above
///   doesn't fire in that case because the selection didn't change)
@MainActor
final class AttentionService: NSObject, ObservableObject {
    @Published private(set) var needsAttention: Set<Session.ID> = []

    private let store: SessionStore
    private let hostRegistry: HostRegistry
    private var lastStatus: [Session.ID: SessionStatus] = [:]
    private var idleDebounceTasks: [Session.ID: Task<Void, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// How long a session has to stay idle before we treat it as
    /// "waiting for input" — a single keystroke can briefly flip
    /// the state to idle and back, so a small debounce avoids spammy
    /// notifications for those.
    private let debounceSeconds: UInt64 = 2_500_000_000

    /// UserDefaults key for the on/off toggle in Settings.
    static let notificationsEnabledDefaultsKey = "notifyOnIdle"

    // MARK: - Prompt-cache expiry

    /// Sessions whose prompt cache is inside its final minute, or already
    /// past it. Drives the sidebar/tab indicator; independent of whether
    /// the banner is enabled.
    @Published private(set) var cacheExpiring: Set<Session.ID> = []

    static let cacheWarningsEnabledDefaultsKey = "warnOnCacheExpiry"

    /// How long before expiry to warn.
    private let cacheWarningLead: TimeInterval = 60
    /// Sessions already warned for the current lull, so a session doesn't
    /// re-notify every tick while it sits idle.
    private var cacheWarned: Set<Session.ID> = []
    private var cacheTimer: AnyCancellable?

    init(store: SessionStore, hostRegistry: HostRegistry) {
        self.store = store
        self.hostRegistry = hostRegistry
        super.init()
        UNUserNotificationCenter.current().delegate = self

        // React to status changes for transition detection.
        store.$sessions
            .sink { [weak self] sessions in
                Task { @MainActor in self?.handleSessionsChange(sessions) }
            }
            .store(in: &cancellables)

        // Clear attention when the user actively selects the session
        // in the sidebar or via tab — that's the gesture that says
        // "I see it."
        store.$selectedSessionID
            .sink { [weak self] selectedID in
                guard let id = selectedID else { return }
                Task { @MainActor in self?.clearAttention(for: id) }
            }
            .store(in: &cancellables)

        // Clear attention when the user clicks into the docked foreign
        // window of the currently-selected session. The dock area is
        // click-through, so a click in it activates the host app
        // directly (rather than the hub). We treat that activation as
        // "user has acknowledged the session" — same outcome as
        // explicitly clicking the hub tab.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                guard let self,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                Task { @MainActor in self.handleAppActivation(bundleID: bundleID) }
            }
            .store(in: &cancellables)

        // The cache ages while nothing changes, so this can't be driven off
        // store.$sessions — a quiet session publishes nothing. 15s is well
        // inside the 60s lead we need and costs nothing when idle.
        cacheTimer = Timer.publish(every: 15, tolerance: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.evaluateCacheExpiry() }
            }
    }

    /// Claude refreshes the prompt cache on every request, so the clock
    /// starts when a session stops working. `lastActivityAt` mirrors the
    /// per-pid file's `updatedAt`, which is what we anchor to.
    private func evaluateCacheExpiry() {
        var expiring: Set<Session.ID> = []
        let now = Date()

        for session in store.sessions {
            // A working session is actively refreshing its cache, and a
            // closed one has nothing to lose.
            guard session.status == .idle else {
                cacheWarned.remove(session.id)
                continue
            }
            let elapsed = now.timeIntervalSince(session.lastActivityAt)
            let warnAt = session.cacheTTL.duration - cacheWarningLead
            guard elapsed >= warnAt else {
                // Back inside the window — a later lull warns again.
                cacheWarned.remove(session.id)
                continue
            }
            expiring.insert(session.id)
            if !cacheWarned.contains(session.id) {
                cacheWarned.insert(session.id)
                if cacheWarningsEnabled { postCacheWarning(for: session) }
            }
        }
        // Only publish on a real change; this ticks every 15s and would
        // otherwise invalidate every sidebar row for nothing.
        if expiring != cacheExpiring { cacheExpiring = expiring }
    }

    private var cacheWarningsEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.cacheWarningsEnabledDefaultsKey) as? Bool ?? true
    }

    private func postCacheWarning(for session: Session) {
        let content = UNMutableNotificationContent()
        content.title = session.displayTitle
        content.body = "Prompt cache expires in about a minute — reply now to keep it warm, or your next message pays to rebuild the context."
        content.sound = nil
        // Same key the click handler reads, so tapping this focuses the
        // session exactly like an idle banner does.
        content.userInfo = ["sessionID": session.id.uuidString]
        // Distinct identifier so clearing an attention badge doesn't also
        // remove this, and vice versa.
        let request = UNNotificationRequest(
            identifier: "cache-expiry-\(session.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                notifyLog.error("posting cache warning failed: \(error.localizedDescription, privacy: .public)")
            } else {
                notifyLog.notice("posted cache warning for \(session.displayTitle, privacy: .public)")
            }
        }
    }

    /// Called when any application becomes the foreground app.
    /// If the activated app hosts the currently-selected session and
    /// that session has an attention badge, treat the activation as
    /// the user's acknowledgement and clear the badge.
    private func handleAppActivation(bundleID: String) {
        guard let selectedID = store.selectedSessionID,
              needsAttention.contains(selectedID),
              let session = store.sessions.first(where: { $0.id == selectedID }),
              let host = hostRegistry.host(forID: session.hostID),
              host.bundleIdentifier == bundleID else { return }
        clearAttention(for: selectedID)
    }

    /// Request notification permission from the user. Idempotent —
    /// macOS only shows the prompt the first time; subsequent calls
    /// just read the current authorization state.
    func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        // Log the pre-existing state as well as the result. A silent
        // failure here is indistinguishable from "user said no" without
        // it, and the two need completely different fixes — this path
        // once went dead after a re-sign with no way to tell why.
        center.getNotificationSettings { settings in
            notifyLog.notice("authorization status before request: \(settings.authorizationStatus.rawValue, privacy: .public)")
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                notifyLog.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                notifyLog.notice("requestAuthorization granted=\(granted, privacy: .public)")
            }
        }
    }

    private var notificationsEnabled: Bool {
        // Default to enabled when the key has never been written.
        UserDefaults.standard.object(forKey: Self.notificationsEnabledDefaultsKey) as? Bool ?? true
    }

    // MARK: - Transition handling

    private func handleSessionsChange(_ sessions: [Session]) {
        for session in sessions {
            let previous = lastStatus[session.id]
            let current = session.status
            lastStatus[session.id] = current

            if previous == .working, current == .idle {
                scheduleIdleAttention(for: session)
            } else if current != .idle {
                // Out of idle (back to working, or closed) — cancel
                // any pending debounce and clear active attention.
                idleDebounceTasks[session.id]?.cancel()
                idleDebounceTasks.removeValue(forKey: session.id)
                if needsAttention.contains(session.id) {
                    clearAttention(for: session.id)
                }
            }
        }
        // Clean up tracking for sessions that no longer exist.
        let liveIDs = Set(sessions.map(\.id))
        for id in lastStatus.keys where !liveIDs.contains(id) {
            lastStatus.removeValue(forKey: id)
            idleDebounceTasks[id]?.cancel()
            idleDebounceTasks.removeValue(forKey: id)
            if needsAttention.contains(id) {
                clearAttention(for: id)
            }
        }
    }

    private func scheduleIdleAttention(for session: Session) {
        idleDebounceTasks[session.id]?.cancel()
        idleDebounceTasks[session.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceSeconds ?? 2_500_000_000)
            guard let self, !Task.isCancelled else { return }
            // Re-check status: if it's no longer idle (claude
            // started processing again), the debounce was a false
            // alarm.
            guard self.store.sessions.first(where: { $0.id == session.id })?.status == .idle else {
                return
            }
            self.markAttention(for: session)
            self.idleDebounceTasks.removeValue(forKey: session.id)
        }
    }

    private func markAttention(for session: Session) {
        needsAttention.insert(session.id)
        // Notifications fire regardless of whether the hub is the
        // active app. The in-app pulse on the sidebar handles the
        // "user is in the hub looking at the right place" case
        // visually, but the user might be in the hub *and* looking
        // at a different docked terminal — the banner reminds them.
        // The user can disable banners entirely via Settings.
        guard notificationsEnabled else { return }
        postNotification(for: session)
    }

    private func clearAttention(for sessionID: Session.ID) {
        guard needsAttention.contains(sessionID) else { return }
        needsAttention.remove(sessionID)
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [sessionID.uuidString])
    }

    private func postNotification(for session: Session) {
        let content = UNMutableNotificationContent()
        content.title = session.displayTitle
        content.body = "Claude is waiting for input · \(session.cwd.lastPathComponent)"
        content.sound = .default
        content.userInfo = ["sessionID": session.id.uuidString]
        let request = UNNotificationRequest(
            identifier: session.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                notifyLog.error("posting banner failed: \(error.localizedDescription, privacy: .public)")
            } else {
                notifyLog.notice("posted banner for \(session.displayTitle, privacy: .public)")
            }
        }
    }
}

extension AttentionService: UNUserNotificationCenterDelegate {
    /// Foreground presentation — without this, macOS swallows
    /// notifications when the hub is the active app. We explicitly
    /// opt the banner, sound, and Notification Center entry in.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Notification tapped from Notification Center. Activate the
    /// hub and select the originating session — the existing
    /// .onChange in MainView routes this to DockController which
    /// raises the docked window.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let idString = userInfo["sessionID"] as? String,
           let id = UUID(uuidString: idString) {
            Task { @MainActor in self.handleNotificationClick(sessionID: id) }
        }
        completionHandler()
    }

    @MainActor
    private func handleNotificationClick(sessionID: Session.ID) {
        NSApp.activate()
        store.selectedSessionID = sessionID
        clearAttention(for: sessionID)
    }
}
