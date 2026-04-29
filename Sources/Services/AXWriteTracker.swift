import CoreGraphics
import Foundation

/// Tracks AX writes the hub has issued so we can distinguish them
/// from genuine user actions when their notifications come back. Without
/// this, every `setFrame` we issue on a docked window triggers a
/// `kAXMovedNotification` we'd then react to — recomputing layout and
/// re-issuing the same write, ad infinitum.
///
/// Model: a counter per (window, attribute) tuple. `recordWrite` bumps
/// the counter; `consume` decrements it and returns true if there was
/// a pending write to consume (i.e. this event was caused by us).
/// Stale entries time out after `timeout` so a dropped event doesn't
/// permanently mask real user activity.
///
/// Not thread-safe. Use from MainActor only.
final class AXWriteTracker {
    private struct PendingWrite {
        let window: CGWindowID
        let attribute: String
        let timestamp: Date
    }

    private var pending: [PendingWrite] = []
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 0.5) {
        self.timeout = timeout
    }

    /// Record that we wrote `attribute` on `window`. Call this *just
    /// before* the AX write — out-of-order race with the event arrival
    /// is what we're guarding against.
    func recordWrite(window: CGWindowID, attribute: String) {
        purgeStale()
        pending.append(PendingWrite(
            window: window,
            attribute: attribute,
            timestamp: Date()
        ))
    }

    /// Check whether an incoming AX event matches one of our pending
    /// writes. If so, consume the entry and return true (event was
    /// our doing). Otherwise return false (event was user-initiated).
    func consume(window: CGWindowID, attribute: String) -> Bool {
        purgeStale()
        guard let index = pending.firstIndex(where: {
            $0.window == window && $0.attribute == attribute
        }) else { return false }
        pending.remove(at: index)
        return true
    }

    /// Drop pending writes older than `timeout`. They didn't get an
    /// event back (AX coalesced or the system dropped it); we don't
    /// want them to permanently mask future user-initiated events.
    private func purgeStale() {
        let cutoff = Date().addingTimeInterval(-timeout)
        pending.removeAll { $0.timestamp < cutoff }
    }
}
