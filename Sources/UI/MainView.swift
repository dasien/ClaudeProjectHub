import SwiftUI

struct MainView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var selectedSessionID: Session.ID?

    var body: some View {
        NavigationSplitView {
            SessionsSidebar(selection: $selectedSessionID)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            TabbedHostArea(selectedSessionID: $selectedSessionID)
        }
    }
}
