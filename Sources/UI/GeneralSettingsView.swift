import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("appearance") private var appearance: String = "system"
    @AppStorage(AttentionService.notificationsEnabledDefaultsKey)
    private var notifyOnIdle: Bool = true

    @EnvironmentObject private var dismissedHistoricalStore: DismissedHistoricalStore

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

            Section("Hidden Sessions") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(dismissedHistoricalStore.ids.count) hidden")
                        Text("Sessions you've removed from \"Available to Resume.\" The underlying transcripts on disk are untouched.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Reset…", role: .destructive) {
                        confirmReset()
                    }
                    .disabled(dismissedHistoricalStore.ids.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 460)
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore hidden historical sessions?"
        alert.informativeText = "All previously-removed entries will reappear in \"Available to Resume\" on the next scan."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            dismissedHistoricalStore.clear()
        }
    }
}
