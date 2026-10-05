import Darwin
import Foundation
import Combine

@MainActor
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
    /// Set when sessions.json failed to decode *and* couldn't be backed
    /// up: saving would destroy the only copy of the unreadable records.
    private var saveBlocked = false
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

    /// Moves a session to `target`'s position: after it when moving
    /// right, before it when moving left — the live-reorder rule a tab
    /// drag needs as it passes over each tab. The array order *is* the tab
    /// order (the sidebar sorts on its own), so persisting it here is all
    /// the tab bar needs to keep a user's arrangement across restarts.
    func move(_ id: Session.ID, toPositionOf target: Session.ID) {
        guard id != target,
              let from = sessions.firstIndex(where: { $0.id == id }),
              let to = sessions.firstIndex(where: { $0.id == target }) else { return }
        // Inserting at the target's original index does both: moving
        // right, the removal shifted the target left, so this lands after
        // it; moving left, nothing shifted, so this lands before it.
        let session = sessions.remove(at: from)
        sessions.insert(session, at: to)
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
        let decoded: [Session]
        do {
            decoded = try decoder.decode([Session].self, from: data)
        } catch {
            // The whole-array decode is all-or-nothing, so one unreadable
            // record (a hand edit, or a status value from a newer build
            // sharing this file) used to mean an empty list — which the
            // next save then wrote over the file. Keep the original and
            // salvage every record that does decode.
            if CorruptFile.preserve(storeURL, error: error) == nil { saveBlocked = true }
            decoded = SessionStore.decodeIndividually(data, decoder: decoder)
        }
        // Transient AX bindings don't survive a hub restart. The pid does,
        // and so does hostWindowID — the latter is just a CGWindowID
        // number, not an AX element, so it can be used as a recovery
        // breadcrumb in `reattachAll()`: if a window with that id still
        // exists in the host's AX list, we re-bind to exactly the right
        // window instead of falling back to "first window of the host"
        // and possibly cross-wiring sessions. Stale ids are filtered
        // out by `AXSupport.findWindow(matching:in:)` returning nil.
        // Closed sessions clear their hostWindowID — no window means
        // no recovery target.
        sessions = decoded.map { stored in
            var s = stored
            if s.status.isRunning {
                if let pid = s.pid, SessionStore.pidIsAlive(pid) {
                    // Status is reset to .idle; lifecycle monitor will
                    // promote to .working once it polls the session file.
                    s.status = .idle
                } else {
                    s.pid = nil
                    s.status = .closed
                    s.hostWindowID = nil
                }
            } else {
                s.hostWindowID = nil
            }
            return s
        }
    }

    /// `kill(pid, 0)` succeeds (or returns EPERM) iff the process exists.
    /// Reasonable proxy for "is this pid still a live claude."
    private static func pidIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func decodeIndividually(_ data: Data, decoder: JSONDecoder) -> [Session] {
        guard let records = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return records.compactMap { record in
            guard let recordData = try? JSONSerialization.data(withJSONObject: record) else { return nil }
            return try? decoder.decode(Session.self, from: recordData)
        }
    }

    private func save() {
        guard persists, !saveBlocked else { return }
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

    // nonisolated: referenced from `init`'s default argument, which is
    // a nonisolated context, and it only touches FileManager — no
    // actor-isolated state to protect.
    private nonisolated static var defaultStoreURL: URL {
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
