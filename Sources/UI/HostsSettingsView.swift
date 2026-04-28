import SwiftUI

struct HostsSettingsView: View {
    @EnvironmentObject private var hostRegistry: HostRegistry

    @State private var selectedHostID: HostConfig.ID?
    @State private var hostToEdit: HostConfig?
    @State private var presentingNew = false
    @State private var hostToConfirmDelete: HostConfig?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hosts")
                        .font(.headline)
                    Text("Saved to ~/Library/Application Support/ClaudeProjectHub/hosts.json")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // List
            List(selection: $selectedHostID) {
                ForEach(hostRegistry.hosts) { host in
                    HostRow(host: host)
                        .tag(host.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
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

            Divider()

            // Bottom action bar — System Settings-style + / − pair
            HStack(spacing: 4) {
                Button {
                    presentingNew = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Add a host")

                Button {
                    if let id = selectedHostID,
                       let host = hostRegistry.hosts.first(where: { $0.id == id }) {
                        hostToConfirmDelete = host
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(selectedHostID == nil)
                .help("Delete selected host")

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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
                    if selectedHostID == host.id {
                        selectedHostID = nil
                    }
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
            HostIconView(host: host, size: 20)
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
