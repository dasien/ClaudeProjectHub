import Darwin
import Foundation
import Combine

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    /// Sidebar selection lives here (not in a SwiftUI @State) so that
    /// non-UI callers — like SessionLauncherService after a successful
    /// launch — can update which session is selected. Persisted to
    /// UserDefaults across hub restarts so the user comes back to the
    /// session they were last on, not whichever happened to dock last.
    @Published var selectedSessionID: Session.ID?

    /// UserDefaults key for the persisted last-selected session.
    private static let selectedIDDefaultsKey = "ClaudeProjectHubSelectedSessionID"

    private let storeURL: URL
    private let persists: Bool
    private var selectionPersistenceCancellable: AnyCancellable?

    init(storeURL: URL = SessionStore.defaultStoreURL, persists: Bool = true) {
        self.storeURL = storeURL
        self.persists = persists
        load()
        restoreSelectedID()
        installSelectionPersistence()
    }

    /// Read the last-selected session id from UserDefaults and apply
    /// it — but only if the session still exists in the store. A
    /// session that was deleted between runs would otherwise leave a
    /// dangling selection that nothing can act on.
    private func restoreSelectedID() {
        guard persists else { return }
        guard let raw = UserDefaults.standard.string(forKey: Self.selectedIDDefaultsKey),
              let uuid = UUID(uuidString: raw),
              sessions.contains(where: { $0.id == uuid }) else { return }
        selectedSessionID = uuid
    }

    /// Mirror every change to selectedSessionID into UserDefaults so
    /// the next launch can restore it. removeDuplicates avoids
    /// thrashing when SwiftUI republishes the same value.
    private func installSelectionPersistence() {
        guard persists else { return }
        selectionPersistenceCancellable = $selectedSessionID
            .removeDuplicates()
            .sink { id in
                if let id {
                    UserDefaults.standard.set(id.uuidString, forKey: Self.selectedIDDefaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.selectedIDDefaultsKey)
                }
            }
    }

    func add(_ session: Session) {
        sessions.append(session)
        selectedSessionID = session.id
        save()
    }

    func remove(id: Session.ID) {
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id {
            selectedSessionID = nil
        }
        save()
    }

    func update(id: Session.ID, _ mutate: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[index])
        save()
    }

    var sortedForSidebar: [Session] {
        sessions.sorted { lhs, rhs in
            if lhs.status.sortRank != rhs.status.sortRank {
                return lhs.status.sortRank < rhs.status.sortRank
            }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([Session].self, from: data) else { return }
        // Transient AX bindings don't survive a hub restart. The pid does
        // — if the underlying claude process is still alive, the session
        // is still running and `SessionLauncherService.reattachAll()` will
        // re-bind its host window after launch. If the process is dead,
        // mark the session closed and clear the stale pid.
        sessions = decoded.map { stored in
            var s = stored
            s.hostWindowID = nil
            if s.status.isRunning {
                if let pid = s.pid, SessionStore.pidIsAlive(pid) {
                    // Status is reset to .idle; lifecycle monitor will
                    // promote to .working once it polls the session file.
                    s.status = .idle
                } else {
                    s.pid = nil
                    s.status = .closed
                }
            }
            return s
        }
    }

    /// `kill(pid, 0)` succeeds (or returns EPERM) iff the process exists.
    /// Reasonable proxy for "is this pid still a live claude."
    private static func pidIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func save() {
        guard persists else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sessions) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }

    private static var defaultStoreURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("ClaudeProjectHub", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }
}

extension SessionStore {
    static var preview: SessionStore {
        let store = SessionStore(
            storeURL: URL(fileURLWithPath: "/tmp/claudeprojecthub-preview.json"),
            persists: false
        )
        store.sessions = [
            Session(
                cwd: URL(fileURLWithPath: "/Users/bgentry/Source/repos/server"),
                hostID: "terminal-app",
                status: .working,
                lastActivityAt: Date().addingTimeInterval(-60)
            ),
            Session(
                cwd: URL(fileURLWithPath: "/Users/bgentry/Source/repos/web"),
                hostID: "terminal-app",
                status: .idle,
                lastActivityAt: Date().addingTimeInterval(-15 * 60)
            ),
            Session(
                cwd: URL(fileURLWithPath: "/Users/bgentry/Source/repos/clients"),
                hostID: "terminal-app",
                status: .closed,
                lastActivityAt: Date().addingTimeInterval(-2 * 3600)
            )
        ]
        return store
    }
}
