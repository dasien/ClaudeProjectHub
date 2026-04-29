import SwiftUI

struct SessionsSidebar: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var launcher: SessionLauncherService
    @EnvironmentObject private var windowManager: WindowManager
    @EnvironmentObject private var lifecycle: SessionLifecycleMonitor
    @EnvironmentObject private var externalScanner: ExternalSessionScanner
    @EnvironmentObject private var hostRegistry: HostRegistry
    @Environment(\.openSettings) private var openSettings

    @State private var newSessionPresented = false
    @State private var sessionToRename: Session?
    @State private var sessionToResume: Session?

    var body: some View {
        List(selection: $store.selectedSessionID) {
            Section("Sessions") {
                ForEach(store.sortedForSidebar) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            menuItems(for: session)
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            if session.status.isRunning {
                                windowManager.focus(session.id)
                            }
                        })
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
                    }
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
        }
    }

    @ViewBuilder
    private func menuItems(for session: Session) -> some View {
        switch session.status {
        case .idle, .working:
            Button("Show") {
                store.selectedSessionID = session.id
                windowManager.focus(session.id)
            }
            Button("Rename…") { sessionToRename = session }
            Button("Close") {
                lifecycle.close(session.id)
            }
        case .closed:
            Button("Resume…") { sessionToResume = session }
                .disabled(session.claudeSessionId == nil)
            Button("Rename…") { sessionToRename = session }
            Divider()
            Button("Remove from List", role: .destructive) {
                store.remove(id: session.id)
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
