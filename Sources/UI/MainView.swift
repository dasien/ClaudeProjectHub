import SwiftUI

struct MainView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var dockController: DockController

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
        .onChange(of: store.selectedSessionID) { _, newID in
            guard let id = newID,
                  dockController.dockedSessionIDs.contains(id) else { return }
            dockController.setActiveSessionID(id)
        }
    }
}
