import Darwin
import Foundation

/// Watches the `claude` process behind each running session and flips its
/// status to `.closed` when the process exits (whether cleanly or because the
/// user closed the host window). Also exposes an explicit `close` for the
/// right-click action.
@MainActor
final class SessionLifecycleMonitor: ObservableObject {
    private let store: SessionStore
    private let windowManager: WindowManager
    private var monitorTask: Task<Void, Never>?

    init(store: SessionStore, windowManager: WindowManager) {
        self.store = store
        self.windowManager = windowManager
    }

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func close(_ sessionID: Session.ID) {
        windowManager.close(sessionID)
        store.update(id: sessionID) {
            $0.status = .closed
            $0.pid = nil
            $0.lastActivityAt = Date()
        }
    }

    private func poll() {
        for session in store.sessions where session.status == .running {
            guard let pid = session.pid else { continue }
            // kill(pid, 0) is the canonical "is this PID alive" check: it
            // performs error checking but sends no signal. Returns 0 if the
            // process exists, -1 (errno = ESRCH) if not.
            if kill(pid, 0) != 0 {
                store.update(id: session.id) {
                    $0.status = .closed
                    $0.pid = nil
                    $0.lastActivityAt = Date()
                }
                windowManager.unbind(session.id)
            }
        }
    }
}
