import SwiftUI

struct TabbedHostArea: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var windowManager: WindowManager
    @EnvironmentObject private var hostRegistry: HostRegistry
    @EnvironmentObject private var dockController: DockController

    private var runningSessions: [Session] {
        store.sessions.filter { $0.status.isRunning }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            // No explicit Divider() — the transparent hub window has
            // nothing opaque beneath the divider's translucent fill,
            // so you'd see the desktop through that 1px row. The
            // strokeBorder around detailArea provides the visual
            // separation instead, with its top edge flush against the
            // tab bar's bottom.
            detailArea
                .dockAreaFrame { rect in
                    dockController.setDockRect(rect)
                }
                // 1px frame around the dock area — defines the "hole"
                // visually whether or not a foreign window fills it.
                // strokeBorder draws fully inside the bounds (vs
                // .stroke which is half-inside, half-outside) so it
                // doesn't bleed into the tab bar's row.
                // allowsHitTesting(false) so the stroke doesn't absorb
                // clicks meant for the docked window.
                .overlay(
                    Rectangle()
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        .allowsHitTesting(false)
                )
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(runningSessions.enumerated()), id: \.element.id) { index, session in
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
                    // Cmd-1..Cmd-9 switch to the Nth tab. Matches the
                    // browser/IDE convention. Tabs past 9 get no
                    // shortcut. Only fires when the hub is the key
                    // window — if the user is interacting with the
                    // docked terminal directly, Terminal sees the key
                    // event first.
                    .keyboardShortcut(Self.shortcut(for: index))
                    .contextMenu {
                        if dockController.dockedSessionIDs.contains(session.id) {
                            Button("Undock") {
                                dockController.undock(sessionID: session.id)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 32)
        // Tab bar needs an explicit background — the hub window itself
        // is transparent (so the dock area can be a click-through hole),
        // and SwiftUI views without backgrounds would show through.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Cmd-1..Cmd-9 for the first nine tabs; nil beyond.
    private static func shortcut(for index: Int) -> KeyboardShortcut? {
        guard let char = "123456789".dropFirst(index).first else { return nil }
        return KeyboardShortcut(KeyEquivalent(char), modifiers: .command)
    }

    private var detailArea: some View {
        // Always fills the available space — the dockAreaFrame reader
        // measures this view's frame, so it must be the full size of
        // the right pane regardless of placeholder visibility.
        ZStack {
            // When nothing is docked, draw an opaque pane so the area
            // reads as a normal hub region instead of a confusing
            // transparent void. When something is docked, leave it
            // clear so the foreign window shows through.
            if dockController.dockedSessionIDs.isEmpty {
                Color(nsColor: .windowBackgroundColor)
                VStack(spacing: 8) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("New sessions launched here will dock automatically")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding()
            } else {
                // Size filler so the ZStack still measures the full
                // pane frame for dockAreaFrame.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // When something is docked, clicks must pass through the SwiftUI
        // layer to the foreign window underneath. When nothing is
        // docked, normal SwiftUI hit testing absorbs (so clicks don't
        // leak through the hub to the desktop).
        .allowsHitTesting(dockController.dockedSessionIDs.isEmpty)
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
