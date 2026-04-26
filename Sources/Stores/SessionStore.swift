import Foundation
import Combine

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    private let storeURL: URL
    private let persists: Bool

    init(storeURL: URL = SessionStore.defaultStoreURL, persists: Bool = true) {
        self.storeURL = storeURL
        self.persists = persists
        load()
    }

    func add(_ session: Session) {
        sessions.append(session)
        save()
    }

    func remove(id: Session.ID) {
        sessions.removeAll { $0.id == id }
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
        // Transient runtime fields don't survive a hub restart, and we don't
        // yet have process re-attachment, so any session that was .running
        // before the hub quit must be considered .closed now. Otherwise the
        // sidebar would show zombie "running" rows whose AX windows no longer
        // exist, which breaks tab docking for the actually-live session.
        sessions = decoded.map { stored in
            var s = stored
            s.pid = nil
            s.hostWindowID = nil
            if s.status == .running {
                s.status = .closed
            }
            return s
        }
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
                hostKind: .terminalApp,
                status: .running,
                lastActivityAt: Date().addingTimeInterval(-60)
            ),
            Session(
                cwd: URL(fileURLWithPath: "/Users/bgentry/Source/repos/web"),
                hostKind: .terminalApp,
                status: .running,
                lastActivityAt: Date().addingTimeInterval(-15 * 60)
            ),
            Session(
                cwd: URL(fileURLWithPath: "/Users/bgentry/Source/repos/clients"),
                hostKind: .terminalApp,
                status: .closed,
                lastActivityAt: Date().addingTimeInterval(-2 * 3600)
            )
        ]
        return store
    }
}
