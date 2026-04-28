import SwiftUI

/// Root of the macOS Settings scene. Wired to Cmd+, automatically via the
/// `Settings { }` scene in the App definition; also opened from the gear
/// icon in the main window's toolbar.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            HostsSettingsView()
                .tabItem {
                    Label("Hosts", systemImage: "terminal.fill")
                }
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}
