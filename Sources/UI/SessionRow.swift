import SwiftUI

struct SessionRow: View {
    let session: Session
    @EnvironmentObject private var hostRegistry: HostRegistry
    @EnvironmentObject private var attention: AttentionService

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let host = hostRegistry.host(forID: session.hostID) {
                        HostIconView(host: host, size: 12)
                    }
                    Text(hostRegistry.displayName(forID: session.hostID))
                    Text("·")
                    timeText
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .opacity(session.status == .closed ? 0.55 : 1.0)
    }

    @ViewBuilder
    private var timeText: some View {
        switch session.status {
        case .idle, .working:
            // SwiftUI's `.relative` style auto-ticks via an internal timer —
            // good for live sessions, wrong for closed ones (they'd keep
            // counting up forever).
            Text(session.lastActivityAt, style: .relative)
        case .closed:
            Text(session.lastActivityAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        // working: solid green (claude is processing)
        // idle: hollow green (alive, waiting for input)
        // closed: solid grey
        // *** needs attention overrides idle ***: a pulsing light
        // purple dot signals "claude transitioned working → idle and
        // hasn't been viewed since" — surfaces sessions that may be
        // waiting on user input.
        if attention.needsAttention.contains(session.id) {
            PulsingAttentionDot()
        } else {
            switch session.status {
            case .working:
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
            case .idle:
                Circle()
                    .strokeBorder(Color.green, lineWidth: 1.5)
                    .frame(width: 8, height: 8)
            case .closed:
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
            }
        }
    }
}

/// Pulsing dot in macOS badge color — visual cue that this session
/// needs attention. Color matches the standard system app-badge red
/// so the indicator reads as "this thing is waiting for you" the
/// same way unread Mail/Slack badges do. Pulse is subtle (slight
/// scale + opacity over ~1.1s) so it draws the eye without becoming
/// distracting in a list of many sessions.
private struct PulsingAttentionDot: View {
    @State private var pulse: Bool = false

    var body: some View {
        Circle()
            .fill(Color(nsColor: .systemRed))
            .frame(width: 8, height: 8)
            .scaleEffect(pulse ? 1.35 : 1.0)
            .opacity(pulse ? 0.55 : 1.0)
            .animation(
                .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
    }
}
