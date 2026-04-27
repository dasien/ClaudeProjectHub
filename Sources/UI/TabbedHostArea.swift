import SwiftUI

struct TabbedHostArea: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var windowManager: WindowManager

    private var runningSessions: [Session] {
        store.sessions.filter { $0.status == .running }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            detailArea
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(runningSessions) { session in
                    TabChip(
                        title: session.displayTitle,
                        isActive: session.id == store.selectedSessionID
                    ) {
                        // Always focus, even if this tab is already selected:
                        // setting the binding to the same value wouldn't trigger
                        // an onChange-based focus path.
                        store.selectedSessionID = session.id
                        windowManager.focus(session.id)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 32)
    }

    private var detailArea: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 8) {
                if let id = store.selectedSessionID,
                   let session = store.sessions.first(where: { $0.id == id }) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(session.displayTitle)
                        .font(.title3)
                    Text(session.displayPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Session is running in its own \(session.hostKind.displayName) window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    Text("Select a session to focus its window")
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding()
        }
    }
}

private struct TabChip: View {
    let title: String
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
