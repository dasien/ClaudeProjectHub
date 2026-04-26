import SwiftUI

struct SessionsSidebar: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var launcher: SessionLauncherService
    @EnvironmentObject private var windowManager: WindowManager
    @EnvironmentObject private var lifecycle: SessionLifecycleMonitor
    @Binding var selection: Session.ID?

    @State private var newSessionPresented = false

    var body: some View {
        List(selection: $selection) {
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
                selection = session.id
                windowManager.focus(session.id)
            }
            Button("Close") {
                lifecycle.close(session.id)
            }
        case .closed:
            Button("Resume") {
                // Future: claude --resume <id> on hostKind in cwd
            }
            .disabled(true)
            Divider()
            Button("Remove from List", role: .destructive) {
                store.remove(id: session.id)
            }
        }
    }
}
