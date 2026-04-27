import SwiftUI

struct SessionsSidebar: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var launcher: SessionLauncherService
    @EnvironmentObject private var windowManager: WindowManager
    @EnvironmentObject private var lifecycle: SessionLifecycleMonitor

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
                            if session.status == .running {
                                windowManager.focus(session.id)
                            }
                        })
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

    @ViewBuilder
    private func menuItems(for session: Session) -> some View {
        switch session.status {
        case .running:
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
