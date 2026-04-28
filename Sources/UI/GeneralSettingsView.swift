import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("appearance") private var appearance: String = "system"

    var body: some View {
        Form {
            Picker("Appearance:", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 400)
    }
}
