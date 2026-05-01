import SwiftUI

struct MainView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var dockController: DockController
    @EnvironmentObject private var windowManager: WindowManager

    var body: some View {
        NavigationSplitView {
            SessionsSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                // Match the sidebar material to the titlebar so the
                // sidebar reads as part of the hub chrome instead of
                // looking too transparent against the hub's overall
                // translucent window.
                .background(VisualEffectView(material: .titlebar))
        } detail: {
            TabbedHostArea()
        }
        .background(HubWindowConfigurator { window in
            dockController.attachHubWindow(window)
        })
        // Keep DockController's notion of "active tab" in sync with
        // the SwiftUI selection. Without this the docked window we
        // re-raise on hub move or app-switch can be a different
        // session than the one the user thinks is selected — the
        // tab highlights one session but the docked window shown is
        // another.
        //
        // The setActiveSessionID call is deferred via DispatchQueue
        // because it publishes changes (activeSessionID), and doing
        // that synchronously inside .onChange triggers SwiftUI's
        // "Publishing changes from within view updates is not
        // allowed" warning. The undefined-behavior consequence:
        // SwiftUI sometimes rolls back the original selection
        // update, making sidebar/tab clicks intermittently fail to
        // register. Pushing the publish to the next run loop tick
        // avoids the conflict.
        .onChange(of: store.selectedSessionID) { _, newID in
            guard let id = newID else { return }
            // Two side effects of selection change, both deferred
            // out of the view update via Task @MainActor:
            // - Docked session: tell DockController to make it the
            //   active tab (raises the AX window via the gate).
            // - Undocked running session: bring its free-floating
            //   window forward via windowManager.focus.
            // Closed sessions: nothing to do.
            Task { @MainActor in
                if dockController.dockedSessionIDs.contains(id) {
                    dockController.setActiveSessionID(id)
                } else if let session = store.sessions.first(where: { $0.id == id }),
                          session.status.isRunning {
                    windowManager.focus(id)
                }
            }
        }
    }
}
