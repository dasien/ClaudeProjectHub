import SwiftUI

struct RenameSessionDialog: View {
    let session: Session
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Session").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.subheadline).foregroundStyle(.secondary)
                TextField("Leave blank to use directory name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(save)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            name = session.name ?? ""
            nameFocused = true
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        store.update(id: session.id) {
            $0.name = trimmed.isEmpty ? nil : trimmed
        }
        dismiss()
    }
}
