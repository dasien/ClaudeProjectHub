import SwiftUI

struct MainView: View {
    var body: some View {
        NavigationSplitView {
            SessionsSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            TabbedHostArea()
        }
    }
}
