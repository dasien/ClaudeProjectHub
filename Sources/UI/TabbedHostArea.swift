import SwiftUI

struct TabbedHostArea: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var windowManager: WindowManager
    @EnvironmentObject private var hostRegistry: HostRegistry
    @EnvironmentObject private var dockController: DockController
    /// The tab being dragged, so hovering over another tab knows what to
    /// move. Cleared on drop; a drag that ends outside the bar leaves it
    /// set harmlessly — the next drag overwrites it.
    @State private var draggingID: Session.ID?

    /// Sessions that get a tab: running *and* still backed by a window.
    ///
    /// The window check matters because a claude process can outlive its
    /// host window by several seconds (iTerm2 tears the session down, then
    /// claude does its own SIGHUP cleanup). Filtering on `status.isRunning`
    /// alone left a tab sitting there through that gap — and a tab whose
    /// window is gone is a broken affordance, since clicking it can't show
    /// or raise anything. The sidebar row is the right place to represent
    /// "process still alive"; it keeps showing the session until the pid
    /// actually exits.
    private var runningSessions: [Session] {
        store.sessions.filter { session in
            guard session.status.isRunning else { return false }
            return dockController.dockedSessionIDs.contains(session.id)
                || windowManager.boundSessionIDs.contains(session.id)
        }
    }

    /// Inset between the dock area and the hub window's right/bottom
    /// edges. Without this, a docked foreign window covers the hub
    /// window's resize edges and the user can't drag them to resize.
    /// Matches the sidebar's natural inset visually.
    private static let dockInset: CGFloat = 8

    /// Shape used for both the dock-area background clip and the
    /// 1px stroke border. Only the top corners are rounded so the
    /// frame hugs the foreign window's macOS-rendered rounded
    /// corners. Radius ≈ standard macOS window corner radius.
    private static let dockShape = UnevenRoundedRectangle(
        topLeadingRadius: 10,
        bottomLeadingRadius: 0,
        bottomTrailingRadius: 0,
        topTrailingRadius: 10
    )

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
                // Round only the TOP corners to roughly match the
                // foreign window's macOS-rendered corner radius (~10px),
                // so the frame visually hugs the docked window instead
                // of cutting a square hole around its rounded edges.
                // Bottom corners stay square — the dock-area inset
                // padding hides them anyway, and the bottom of the dock
                // area sits against the hub window's own bottom corners.
                // clipShape applies to the placeholder background so it
                // ALSO has rounded tops, not just the stroke.
                .clipShape(Self.dockShape)
                .overlay(
                    Self.dockShape
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .padding(.trailing, Self.dockInset)
                .padding(.bottom, Self.dockInset)
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(runningSessions.enumerated()), id: \.element.id) { index, session in
                    TabChip(
                        title: session.displayTitle,
                        host: hostRegistry.host(forID: session.hostID),
                        isActive: session.id == store.selectedSessionID,
                        isMinimized: dockController.minimizedSessionIDs.contains(session.id)
                    ) {
                        store.selectedSessionID = session.id
                        // Same reasoning as the sidebar tap — DockController
                        // raises (without activating) docked sessions via
                        // the .onChange sync in MainView. Only fire
                        // windowManager.focus for sessions that are running
                        // but not currently docked, where there's no other
                        // path to bring the foreign window forward.
                        if !dockController.dockedSessionIDs.contains(session.id) {
                            windowManager.focus(session.id)
                        }
                    }
                    // Cmd-1..Cmd-9 switch to the Nth tab. Matches the
                    // browser/IDE convention. Tabs past 9 get no
                    // shortcut. Only fires when the hub is the key
                    // window — if the user is interacting with the
                    // docked terminal directly, Terminal sees the key
                    // event first.
                    .keyboardShortcut(Self.shortcut(for: index))
                    // Drag to reorder. Tabs move live as the drag passes
                    // over them, so the order is already final by drop
                    // time; Cmd-1..9 follow the new order.
                    .onDrag {
                        draggingID = session.id
                        return NSItemProvider(object: session.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: TabReorderDelegate(
                        target: session.id,
                        draggingID: $draggingID,
                        store: store
                    ))
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 40)
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
        //
        // Two empty states the placeholder covers:
        //   - No docked sessions at all → guide the user toward
        //     launching one.
        //   - Docked sessions exist but all are minimized/hidden →
        //     tell them how to bring one back.
        // Both render an opaque pane so the area reads as a normal
        // hub region instead of a transparent void. When at least one
        // session is visibly docked, the pane is clear and the
        // foreign window shows through.
        ZStack {
            if dockController.visibleDockedSessionIDs.isEmpty {
                Color(nsColor: .windowBackgroundColor)
                VStack(spacing: 8) {
                    Image(systemName: placeholderIcon)
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(placeholderText)
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
        // When a visible foreign window exists, clicks must pass
        // through the SwiftUI layer to it. With no visible docked
        // window (no docks at all, or all hidden), normal SwiftUI hit
        // testing absorbs so clicks don't leak through to the desktop.
        .allowsHitTesting(dockController.visibleDockedSessionIDs.isEmpty)
    }

    private var placeholderIcon: String {
        dockController.dockedSessionIDs.isEmpty
            ? "macwindow.on.rectangle"
            : "eye.slash"
    }

    private var placeholderText: String {
        dockController.dockedSessionIDs.isEmpty
            ? "New sessions launched here will dock automatically"
            : "All docked sessions are hidden. Click a tab to bring one back."
    }
}

private struct TabReorderDelegate: DropDelegate {
    let target: Session.ID
    @Binding var draggingID: Session.ID?
    let store: SessionStore

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            store.move(dragging, toPositionOf: target)
        }
    }

    // .move rather than the default .copy, so the cursor doesn't show
    // a "+" badge for what is a rearrangement.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

private struct TabChip: View {
    let title: String
    let host: HostConfig?
    let isActive: Bool
    let isMinimized: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if let host {
                    HostIconView(host: host, size: 18)
                }
                Text(title)
                    .italic(isMinimized)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
            .foregroundStyle(isActive ? Color.accentColor : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            // Match SessionRow's minimized treatment: italic title +
            // 0.7 opacity. Two surfaces use the same visual vocabulary
            // for the same state.
            .opacity(isMinimized ? 0.7 : 1.0)
        }
        .buttonStyle(.plain)
    }
}
