import SwiftUI

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(session.hostKind.displayName)
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
