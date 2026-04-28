import SwiftUI

struct HostsSettingsView: View {
    @EnvironmentObject private var hostRegistry: HostRegistry
    @State private var hostToEdit: HostConfig?
    @State private var presentingNew = false
    @State private var hostToConfirmDelete: HostConfig?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hosts")
                        .font(.headline)
                    Text("Saved to ~/Library/Application Support/ClaudeProjectHub/hosts.json")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    presentingNew = true
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            List {
                ForEach(hostRegistry.hosts) { host in
                    HostRow(host: host)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            hostToEdit = host
                        }
                        .contextMenu {
                            Button("Edit…") { hostToEdit = host }
                            Divider()
                            Button("Delete…", role: .destructive) {
                                hostToConfirmDelete = host
                            }
                        }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .sheet(isPresented: $presentingNew) {
            HostEditorView(editingHost: nil)
        }
        .sheet(item: $hostToEdit) { host in
            HostEditorView(editingHost: host)
        }
        .alert(
            "Delete \(hostToConfirmDelete?.displayName ?? "host")?",
            isPresented: Binding(
                get: { hostToConfirmDelete != nil },
                set: { if !$0 { hostToConfirmDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { hostToConfirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let host = hostToConfirmDelete {
                    hostRegistry.remove(id: host.id)
                }
                hostToConfirmDelete = nil
            }
        } message: {
            Text("Existing sessions launched on this host won't be affected, but you won't be able to launch new sessions on it until you re-add it.")
        }
    }
}

private struct HostRow: View {
    let host: HostConfig

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: host.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.body)
                Text(strategyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(host.id)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospaced()
        }
        .padding(.vertical, 4)
    }

    private var strategyDescription: String {
        switch host.strategy {
        case .builtin(let kind):
            return "Built-in · \(kind.rawValue)"
        case .process(let executable, _):
            return "Process · \(executable)"
        }
    }
}
