import Darwin
import Foundation
import Combine

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    /// Sidebar selection lives here (not in a SwiftUI @State) so that
    /// non-UI callers — like SessionLauncherService after a successful
    /// launch — can update which session is selected.
    @Published var selectedSessionID: Session.ID?

    private let storeURL: URL
    private let persists: Bool

    init(storeURL: URL = SessionStore.defaultStoreURL, persists: Bool = true) {
        self.storeURL = storeURL
        self.persists = persists
        load()
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
