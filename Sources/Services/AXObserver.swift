import ApplicationServices
import CoreFoundation
import Darwin

/// Pid-scoped wrapper around `AXObserverCreate`. Subscribes to AX
/// notifications on specific `AXUIElement`s (typically windows) and
/// fans the callbacks out to a Swift closure on the main run loop.
///
/// Lifecycle:
///   1. `init(pid:)` creates the underlying observer and adds its
///      run-loop source to the current thread's run loop.
///   2. `subscribe(element:notifications:)` registers per-element
///      interest. Notifications fire until you `unsubscribe`.
///   3. `deinit` removes the run-loop source and lets ARC drop the
///      AXObserverRef.
///
/// Notifications we care about for docking:
///   - `kAXMovedNotification`            — window position changed
///   - `kAXResizedNotification`          — window size changed
///   - `kAXUIElementDestroyedNotification` — window closed
///   - `kAXTitleChangedNotification`     — window title changed
///   - `kAXWindowMiniaturizedNotification`
///   - `kAXWindowDeminiaturizedNotification`
///
/// AX events for the observer are delivered on the main run loop. The
/// callback closure is invoked there too, so consumers can update
/// `@MainActor` state without hopping threads.
final class AXObserver {
    /// One emitted notification.
    struct Event {
        let name: String
        let element: AXUIElement
    }

    typealias Callback = (Event) -> Void

    private let observer: ApplicationServices.AXObserver
    private let callback: Callback
    private(set) var pid: pid_t

    /// Returns nil if AX trust isn't granted or the pid doesn't have
    /// an accessible application.
    init?(pid: pid_t, callback: @escaping Callback) {
        self.pid = pid
        self.callback = callback

        var observerRef: ApplicationServices.AXObserver?
        // The C callback bridges back to our Swift closure via the
        // `refcon` pointer we'll pass when subscribing.
        let cCallback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<AXObserver>.fromOpaque(refcon).takeUnretainedValue()
            observer.callback(Event(
                name: notification as String,
                element: element
            ))
        }

        let err = AXObserverCreate(pid, cCallback, &observerRef)
        guard err == .success, let created = observerRef else { return nil }
        self.observer = created

        // Get notifications delivered on the current (main) run loop.
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(created),
            .defaultMode
        )
    }

    deinit {
        CFRunLoopRemoveSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }

    /// Subscribe to a list of AX notifications for `element`. Repeated
    /// calls for the same (element, notification) pair are no-ops at
    /// the AX layer — duplicate subscriptions return an error which
    /// we silently swallow.
    func subscribe(element: AXUIElement, notifications: [String]) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in notifications {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
    }

    /// Unsubscribe a list of AX notifications from `element`.
    /// Unsubscribing one we didn't subscribe to is a no-op.
    func unsubscribe(element: AXUIElement, notifications: [String]) {
        for name in notifications {
            AXObserverRemoveNotification(observer, element, name as CFString)
        }
    }
}

/// AX notification name constants in a Swift-friendly namespace.
/// These match the C constants from `AXNotificationConstants.h` but
/// are easier to compose in arrays than scattered `kAX*Notification`
/// references.
enum AXNotification {
    static let moved = kAXMovedNotification as String
    static let resized = kAXResizedNotification as String
    static let destroyed = kAXUIElementDestroyedNotification as String
    static let titleChanged = kAXTitleChangedNotification as String
    static let miniaturized = kAXWindowMiniaturizedNotification as String
    static let deminiaturized = kAXWindowDeminiaturizedNotification as String
    static let windowCreated = kAXWindowCreatedNotification as String
    static let focusedWindowChanged = kAXFocusedWindowChangedNotification as String
}
