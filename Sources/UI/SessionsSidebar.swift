import SwiftUI

struct SessionsSidebar: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var launcher: SessionLauncherService
    @EnvironmentObject private var windowManager: WindowManager
    @EnvironmentObject private var lifecycle: SessionLifecycleMonitor
    @EnvironmentObject private var externalScanner: ExternalSessionScanner
    @EnvironmentObject private var historicalScanner: HistoricalSessionScanner
    @EnvironmentObject private var dismissedHistoricalStore: DismissedHistoricalStore
    @EnvironmentObject private var hostRegistry: HostRegistry
    @EnvironmentObject private var dockController: DockController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @State private var newSessionPresented = false
    @State private var sessionToRename: Session?
    @State private var sessionToResume: Session?
    @State private var historicalToResume: HistoricalSession?

    // Select-mode state for "Available to Resume". `historicalSelection`
    // holds claudeSessionIds. `lastDismissed` powers the transient
    // header Undo affordance; it auto-clears after `undoTimeout` so the
    // section doesn't show a stale Undo forever.
    @State private var selectingHistorical = false
    @State private var historicalSelection: Set<String> = []
    @State private var lastDismissed: Set<String>?
    @State private var undoExpiryTask: Task<Void, Never>?
    private let undoTimeout: TimeInterval = 6

    var body: some View {
        List(selection: $store.selectedSessionID) {
            Section("Sessions") {
                ForEach(store.sortedForSidebar) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            menuItems(for: session)
                        }
                        // No simultaneousGesture / onDrag on List
                        // rows on macOS — both compete with List's
                        // own selection gesture and produce
                        // intermittent failures where the gesture
                        // fires but the selection binding never
                        // updates. The diagnostic output (gesture
                        // fires but no [publish] SessionStore on
                        // failed clicks) made this clear. Side
                        // effects driven by selection live in
                        // MainView.onChange instead.
                }
            }
            if !externalScanner.sessions.isEmpty {
                Section("Available to Dock") {
                    ForEach(externalScanner.sessions) { external in
                        ExternalSessionRow(session: external)
                            .contextMenu {
                                Button("Adopt and Dock") {
                                    Task { await adopt(external) }
                                }
                            }
                            // Same caveat as the running-session rows
                            // above: .onDrag on a List row absorbs
                            // click events. Right-click → Adopt and
                            // Dock is the supported path until we add
                            // a proper drag handle.
                    }
                }
            }
            if !historicalScanner.sessions.isEmpty {
                Section {
                    ForEach(historicalScanner.sessions) { historical in
                        historicalRow(for: historical)
                    }
                } header: {
                    historicalHeader
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("New Session…") { startNewSession() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: startNewSession) {
                    Label("New Session", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $newSessionPresented) {
            NewSessionDialog()
        }
        .sheet(item: $sessionToRename) { session in
            RenameSessionDialog(session: session)
        }
        .sheet(item: $sessionToResume) { session in
            ResumeSessionDialog(session: session)
        }
        .sheet(item: $historicalToResume) { historical in
            HistoricalResumeDialog(historical: historical)
        }
    }

    private func startNewSession() {
        guard launcher.ensureAccessibilityOrPrompt() else { return }
        newSessionPresented = true
    }

    private func adopt(_ external: ExternalSession) async {
        guard launcher.ensureAccessibilityOrPrompt() else { return }
        let success = await launcher.adopt(external)
        if success {
            externalScanner.refresh()
            historicalScanner.refresh()
        }
    }

    /// Re-dock a running session that's currently free-floating
    /// (e.g. user undocked it earlier via drag-titlebar-out or
    /// right-click). Reuses the AX window binding still held in
    /// WindowManager and re-derives the host's tty for tab switching.
    private func redock(_ session: Session) {
        guard let window = windowManager.binding(for: session.id) else { return }
        let tabID: String? = session.pid.flatMap { ProcessTree.controllingTTY(of: $0) }
        dockController.dock(
            window: window,
            sessionID: session.id,
            hostID: session.hostID,
            tabID: tabID
        )
        store.selectedSessionID = session.id
    }

    @ViewBuilder
    private func menuItems(for session: Session) -> some View {
        switch session.status {
        case .idle, .working:
            Button("Show") {
                store.selectedSessionID = session.id
                windowManager.focus(session.id)
            }
            if dockController.dockedSessionIDs.contains(session.id) {
                Button("Undock") {
                    dockController.undock(sessionID: session.id)
                }
            } else {
                Button("Dock") {
                    redock(session)
                }
            }
            Button("Rename…") { sessionToRename = session }
            Button("Close") {
                lifecycle.close(session.id)
            }
            Divider()
            Button("Get Info") {
                openWindow(id: "session-info", value: session.id)
            }
        case .closed:
            Button("Resume…") { sessionToResume = session }
                .disabled(session.claudeSessionId == nil)
            Button("Rename…") { sessionToRename = session }
            Button("Remove from List", role: .destructive) {
                store.remove(id: session.id)
            }
            Divider()
            Button("Get Info") {
                openWindow(id: "session-info", value: session.id)
            }
        }
    }

    // MARK: - "Available to Resume" header + rows

    @ViewBuilder
    private var historicalHeader: some View {
        HStack(spacing: 8) {
            if selectingHistorical {
                Text("\(historicalSelection.count) selected")
            } else {
                Text("Available to Resume")
            }
            Spacer()
            if selectingHistorical {
                Button("Remove (\(historicalSelection.count))", role: .destructive) {
                    removeSelected()
                }
                .buttonStyle(.borderless)
                .disabled(historicalSelection.isEmpty)
                Button("Done") { exitSelectMode() }
                    .buttonStyle(.borderless)
            } else {
                if lastDismissed != nil {
                    Button("Undo") { undoLastDismissal() }
                        .buttonStyle(.borderless)
                }
                Button("Select") { enterSelectMode() }
                    .buttonStyle(.borderless)
            }
        }
        // Preserve "Available to Resume" capitalization; default List
        // sidebar styling uppercases section headers.
        .textCase(nil)
    }

    @ViewBuilder
    private func historicalRow(for historical: HistoricalSession) -> some View {
        if selectingHistorical {
            // Wrap the row in a Button so the entire row is the
            // hit target — matches Mail.app/Finder list-edit
            // affordances. .plain style strips default chrome.
            Button {
                toggleHistoricalSelection(historical)
            } label: {
                HStack(spacing: 8) {
                    let selected = historicalSelection.contains(historical.claudeSessionId)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    HistoricalSessionRow(session: historical)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HistoricalSessionRow(session: historical)
                .contextMenu {
                    Button("Resume…") {
                        historicalToResume = historical
                    }
                    Divider()
                    Button("Remove from List", role: .destructive) {
                        dismissOne(historical)
                    }
                    Button("Select All in This Project") {
                        selectProject(of: historical)
                    }
                }
        }
    }

    // MARK: - Select-mode actions

    private func enterSelectMode() {
        selectingHistorical = true
        historicalSelection = []
    }

    private func exitSelectMode() {
        selectingHistorical = false
        historicalSelection = []
    }

    private func toggleHistoricalSelection(_ historical: HistoricalSession) {
        let id = historical.claudeSessionId
        if historicalSelection.contains(id) {
            historicalSelection.remove(id)
        } else {
            historicalSelection.insert(id)
        }
    }

    /// Enters select mode pre-checking every row whose cwd matches the
    /// right-clicked row's. The user uncheck-and-keeps as desired,
    /// then taps Remove (N).
    private func selectProject(of historical: HistoricalSession) {
        let path = historical.cwd.path
        let matches = historicalScanner.sessions
            .filter { $0.cwd.path == path }
            .map { $0.claudeSessionId }
        historicalSelection = Set(matches)
        selectingHistorical = true
    }

    private func dismissOne(_ historical: HistoricalSession) {
        let payload: Set<String> = [historical.claudeSessionId]
        lastDismissed = payload
        dismissedHistoricalStore.dismiss(historical.claudeSessionId)
        scheduleUndoExpiry()
    }

    private func removeSelected() {
        let payload = historicalSelection
        guard !payload.isEmpty else { return }
        lastDismissed = payload
        dismissedHistoricalStore.dismiss(payload)
        exitSelectMode()
        scheduleUndoExpiry()
    }

    private func undoLastDismissal() {
        guard let payload = lastDismissed else { return }
        dismissedHistoricalStore.restore(payload)
        lastDismissed = nil
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
    }

    private func scheduleUndoExpiry() {
        undoExpiryTask?.cancel()
        let timeout = undoTimeout
        undoExpiryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled {
                lastDismissed = nil
                undoExpiryTask = nil
            }
        }
    }
}

/// Sidebar row for a claude session running on the machine that the
/// hub didn't launch. Shows the cwd basename and the host app's
/// icon. Right-click → Adopt and Dock.
private struct ExternalSessionRow: View {
    let session: ExternalSession
    @EnvironmentObject private var hostRegistry: HostRegistry

    var body: some View {
        HStack(spacing: 8) {
            if let hostID = session.hostID,
               let host = hostRegistry.host(forID: hostID) {
                HostIconView(host: host, size: 16)
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.cwd.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.cwd.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        // No .tag — these rows aren't selectable in the same list
        // selection space as hub-tracked sessions. Adopt is via
        // right-click only, intentionally a deliberate action.
    }
}

/// Sidebar row for a closed claude session the hub didn't launch,
/// discovered on disk by `HistoricalSessionScanner`. Right-click →
/// Resume… picks a host and runs the standard resume flow against it.
private struct HistoricalSessionRow: View {
    let session: HistoricalSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.cwd.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let summary = session.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(session.cwd.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
