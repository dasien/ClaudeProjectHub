import AppKit
import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject private var hostRegistry: HostRegistry
    @Environment(\.dismiss) private var dismiss

    /// nil when creating a new host; populated when editing an existing one.
    let editingHost: HostConfig?

    @State private var id: String = ""
    @State private var displayName: String = ""
    @State private var icon: String = "terminal.fill"
    @State private var bundleIdentifier: String = ""
    @State private var strategyType: StrategyType = .builtin
    @State private var builtinKind: BuiltinKind = .terminalApp
    @State private var executable: String = ""
    @State private var arguments: [String] = []

    private enum StrategyType: String, CaseIterable {
        case builtin
        case process

        var displayName: String {
            switch self {
            case .builtin: return "Built-in"
            case .process: return "Process"
            }
        }
    }

    private var isEditing: Bool { editingHost != nil }

    private var canSave: Bool {
        guard !id.trimmingCharacters(in: .whitespaces).isEmpty,
              !displayName.trimmingCharacters(in: .whitespaces).isEmpty,
              !icon.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // Don't let user create a host whose id collides with another host's id.
        if !hostRegistry.isIDAvailable(id, excluding: editingHost?.id) { return false }
        if strategyType == .process && executable.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Edit Host" : "New Host")
                .font(.headline)

            field(label: "ID") {
                TextField("e.g. ghostty", text: $id)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditing) // changing id post-creation breaks Session.hostID references
                    .help(isEditing ? "Existing sessions reference this id; not editable." : "")
            }

            field(label: "Display Name") {
                TextField("e.g. Ghostty", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            field(label: "Icon (SF Symbol)") {
                HStack {
                    TextField("e.g. terminal.fill", text: $icon)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                }
            }

            field(label: "Bundle Identifier") {
                TextField("e.g. com.mitchellh.ghostty (recommended)", text: $bundleIdentifier)
                    .textFieldStyle(.roundedBorder)
            }

            field(label: "Strategy") {
                Picker("", selection: $strategyType) {
                    ForEach(StrategyType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch strategyType {
            case .builtin:
                field(label: "Built-in Kind") {
                    Picker("", selection: $builtinKind) {
                        ForEach(BuiltinKind.allCases, id: \.self) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: builtinKind) { _, newKind in
                        prefillFromBuiltinKind(newKind)
                    }
                }

            case .process:
                field(label: "Executable") {
                    HStack {
                        TextField("/Applications/Ghostty.app/Contents/MacOS/ghostty",
                                  text: $executable)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…", action: browseExecutable)
                    }
                }

                field(label: "Arguments") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(arguments.indices, id: \.self) { index in
                            HStack {
                                TextField("argument", text: $arguments[index])
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    arguments.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button {
                            arguments.append("")
                        } label: {
                            Label("Add Argument", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        Text("Tokens: {cwd}, {claude}, {command}")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { loadFromEditing() }
    }

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
    }

    private func loadFromEditing() {
        guard let host = editingHost else { return }
        id = host.id
        displayName = host.displayName
        icon = host.icon
        bundleIdentifier = host.bundleIdentifier ?? ""
        switch host.strategy {
        case .builtin(let kind):
            strategyType = .builtin
            builtinKind = kind
        case .process(let exe, let args):
            strategyType = .process
            executable = exe
            arguments = args
        }
    }

    /// When the user picks a builtin kind in a NEW host, fill in sensible
    /// defaults for any fields they haven't already set.
    private func prefillFromBuiltinKind(_ kind: BuiltinKind) {
        guard !isEditing else { return }
        if id.isEmpty { id = kind.rawValue }
        if displayName.isEmpty { displayName = kind.suggestedDisplayName }
        if bundleIdentifier.isEmpty { bundleIdentifier = kind.suggestedBundleIdentifier }
        if icon.isEmpty { icon = kind.suggestedIcon }
    }

    private func save() {
        let trimmedID = id.trimmingCharacters(in: .whitespaces)
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let trimmedIcon = icon.trimmingCharacters(in: .whitespaces)
        let trimmedBundle = bundleIdentifier.trimmingCharacters(in: .whitespaces)

        let strategy: HostStrategy
        switch strategyType {
        case .builtin:
            strategy = .builtin(builtinKind)
        case .process:
            strategy = .process(
                executable: executable.trimmingCharacters(in: .whitespaces),
                arguments: arguments
            )
        }

        let host = HostConfig(
            id: trimmedID,
            displayName: trimmedName,
            icon: trimmedIcon,
            bundleIdentifier: trimmedBundle.isEmpty ? nil : trimmedBundle,
            strategy: strategy
        )

        if isEditing {
            hostRegistry.update(host)
        } else {
            hostRegistry.add(host)
        }
        dismiss()
    }

    private func browseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // .app bundles are technically directories; let the user navigate
        // into them to pick the actual executable inside Contents/MacOS.
        panel.treatsFilePackagesAsDirectories = true
        panel.title = "Select host executable"
        if panel.runModal() == .OK, let url = panel.url {
            executable = url.path
        }
    }
}
