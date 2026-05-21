import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Interpolates a foreign window's AX frame from a start rect to a
/// target rect over a short duration with an ease-out cubic curve.
/// Each interpolated frame is written via the shared `AXWriteTracker`
/// so the resulting `kAXMoved` / `kAXResized` notifications get
/// flagged as self-caused and filtered by `DockController`'s
/// user-initiated path.
///
/// Used for dock/undock transitions — short, one-shot animations where
/// the foreign window glides into or out of the dock rect rather than
/// snapping instantly. NOT used during hub drag/resize: those need
/// immediate per-frame updates so the docked window stays glued to the
/// hub at 60+Hz.
///
/// New animations on the same `sessionID` cancel any in-flight
/// animation for that session before starting.
@MainActor
final class FrameAnimator {
    /// Default transition length. 180ms is short enough that mid-
    /// animation user input is unlikely, long enough to read as a
    /// deliberate motion rather than a tear.
    nonisolated static let defaultDuration: TimeInterval = 0.18
    /// Number of interpolated steps. 8 steps over 180ms ≈ 22ms per
    /// step ≈ 45fps — close enough to display refresh that the
    /// foreign app's redraw cycle picks it up smoothly without us
    /// flooding the AX IPC channel. `nonisolated` so it can be used
    /// as a default arg value (default-arg eval happens on the
    /// caller's actor, not this class's).
    nonisolated static let defaultStepCount: Int = 8

    private var tasks: [Session.ID: Task<Void, Never>] = [:]
    private let tracker: AXWriteTracker

    init(tracker: AXWriteTracker) {
        self.tracker = tracker
    }

    /// Animate a window from `start` to `target`. No-op if the rects
    /// are equal. Any in-flight animation for the same `sessionID` is
    /// cancelled first so a rapid dock/undock pair doesn't fight
    /// itself.
    func animate(
        sessionID: Session.ID,
        element: AXUIElement,
        windowID: CGWindowID,
        from start: CGRect,
        to target: CGRect,
        duration: TimeInterval = FrameAnimator.defaultDuration,
        stepCount: Int = FrameAnimator.defaultStepCount
    ) {
        guard start != target else { return }
        tasks[sessionID]?.cancel()
        let tracker = self.tracker
        tasks[sessionID] = Task { @MainActor in
            let stepDuration = duration / Double(stepCount)
            for i in 1...stepCount {
                if Task.isCancelled { return }
                let progress = Double(i) / Double(stepCount)
                let eased = Self.easeOutCubic(progress)
                let frame = Self.interpolate(start: start, target: target, t: eased)
                AXSupport.setFrame(frame, on: element, windowID: windowID, tracker: tracker)
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
            }
        }
    }

    /// Cancel any in-flight animation for `sessionID`. Called by
    /// `DockController.undock` and on window destruction so we don't
    /// keep writing frames to a window the foreign app may have
    /// repositioned or closed.
    func cancel(sessionID: Session.ID) {
        tasks[sessionID]?.cancel()
        tasks.removeValue(forKey: sessionID)
    }

    private static func interpolate(start: CGRect, target: CGRect, t: Double) -> CGRect {
        CGRect(
            x: start.origin.x + (target.origin.x - start.origin.x) * t,
            y: start.origin.y + (target.origin.y - start.origin.y) * t,
            width: start.size.width + (target.size.width - start.size.width) * t,
            height: start.size.height + (target.size.height - start.size.height) * t
        )
    }

    /// Cubic ease-out: fast at first, decelerates to land. Feels
    /// natural for "settling into place" — closer to how a dropped
    /// window would behave physically than linear or ease-in-out.
    private static func easeOutCubic(_ t: Double) -> Double {
        let f = t - 1
        return f * f * f + 1
    }
}
