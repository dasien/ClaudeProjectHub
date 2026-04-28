import SwiftUI

struct HostsSettingsView: View {
    @EnvironmentObject private var hostRegistry: HostRegistry

    @State private var selectedHostID: HostConfig.ID?
    @State private var hostToEdit: HostConfig?
    @State private var presentingNew = false
    @State private var hostToConfirmDelete: HostConfig?

    var body: some View {
        VStack(spacing: 0) {
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

            // Apple's canonical pattern for single-click select + double-click
            // edit + right-click menu on macOS Lists. The contextMenu modifier's
            // primaryAction fires on double-click and on Return.
            List(selection: $selectedHostID) {
                ForEach(hostRegistry.hosts) { host in
                    HostRow(host: host).tag(host.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: HostConfig.ID.self) { ids in
                if let host = host(for: ids) {
                    Button("Edit…") { hostToEdit = host }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        hostToConfirmDelete = host
                    }
                }
            } primaryAction: { ids in
                if let host = host(for: ids) {
                    hostToEdit = host
                }
            }

            Divider()

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
            Text("Existing sessions launched on this host won't be affected, but you won't be able to launch new sessions on it until you re-add it. The launch script file on disk is left in place.")
        }
    }

    /// The contextMenu callbacks receive a Set of selected ids. Single-
    /// selection lists usually have one entry, but right-clicking an
    /// unselected row passes that row's id without changing `selectedHostID`.
    private func host(for ids: Set<HostConfig.ID>) -> HostConfig? {
        guard let id = ids.first else { return nil }
        return hostRegistry.hosts.first { $0.id == id }
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
                Text(host.launchScript)
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
}
