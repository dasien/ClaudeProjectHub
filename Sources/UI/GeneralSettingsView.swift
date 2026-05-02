import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("appearance") private var appearance: String = "system"
    @AppStorage(AttentionService.notificationsEnabledDefaultsKey)
    private var notifyOnIdle: Bool = true

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance:", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Notifications") {
                Toggle(
                    "Notify me when a session is waiting for input",
                    isOn: $notifyOnIdle
                )
                Text("The pulsing indicator on a session row appears regardless of this setting. Banner vs. alert style is controlled in System Settings → Notifications → Claude Project Hub.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 460)
    }
}
