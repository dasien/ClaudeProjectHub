import CoreGraphics
import Foundation

/// The distinct host windows behind a set of running sessions, grouped by
/// `hostWindowID`.
///
/// Every "new tab in…" picker uses these instead of raw sessions, so N tabs
/// sharing one iTerm2/Terminal window collapse into a single row. Picking
/// any tab in a window resolves to the same windowID at launch time, so
/// listing them separately made the choice look meaningful when it wasn't.
struct HostWindowGroup: Identifiable {
    let id: CGWindowID
    /// Most-recently-active first.
    let sessions: [Session]

    private init(id: CGWindowID, sessions: [Session]) {
        self.id = id
        self.sessions = sessions
    }

    /// The launcher maps this back to the window's id, so behavior matches
    /// the older per-session pickers.
    var representativeSessionID: Session.ID { sessions[0].id }

    var displayLabel: String {
        sessions.map(\.displayTitle).joined(separator: ", ")
    }

    /// Sessions with no bound window are dropped — there's no window to
    /// open a tab in, so offering them would fail at launch.
    static func grouped(from sessions: [Session]) -> [HostWindowGroup] {
        Dictionary(grouping: sessions, by: \.hostWindowID)
            .compactMap { windowID, group -> HostWindowGroup? in
                guard let windowID, !group.isEmpty else { return nil }
                return HostWindowGroup(
                    id: windowID,
                    sessions: group.sorted { $0.lastActivityAt > $1.lastActivityAt }
                )
            }
            .sorted {
                ($0.sessions.first?.lastActivityAt ?? .distantPast)
                    > ($1.sessions.first?.lastActivityAt ?? .distantPast)
            }
    }
}
