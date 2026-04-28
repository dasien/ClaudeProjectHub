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
        if !hostRegistry.isIDAvailable(id, excluding: editingHost?.id) { return false }
        if strategyType == .process && executable.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                EditorIconPreview(
                    bundleIdentifier: bundleIdentifier,
                    executable: executable,
                    sfSymbolFallback: icon,
                    size: 32
                )
                Text(isEditing ? "Edit Host" : "New Host")
                    .font(.headline)
            }

            field(
                label: "Identifier",
                helpText: "A unique key sessions store to remember which host they were launched in. Once a host is created, this can't change without orphaning existing sessions."
            ) {
                TextField("e.g. ghostty", text: $id)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditing)
            }

            field(label: "Display Name") {
                TextField("e.g. Ghostty", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            field(
                label: "Bundle Identifier",
                helpText: "The macOS bundle ID of the host app (find via the .app's Info.plist, or just install the app and the hub will show its actual icon when this is set). Used to locate the running process and its icon. Optional but recommended — without it, the hub can't bind to the host's window via Accessibility."
            ) {
                TextField("e.g. com.mitchellh.ghostty", text: $bundleIdentifier)
                    .textFieldStyle(.roundedBorder)
            }

            field(
                label: "Strategy",
                helpText: """
                Built-in: handled by Swift code in the hub. Currently Terminal.app and iTerm2 — these have specific quirks (AppleScript dictionaries, AX patterns) that need per-host code.

                Process: a CLI command the hub runs with token substitution. Use this for any terminal that takes a command-line invocation — Ghostty, Alacritty, WezTerm, kitty, etc. No Swift code needed; just configure the executable and arguments.
                """
            ) {
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

                field(
                    label: "Arguments",
                    helpText: """
                    Passed to the executable verbatim. Available substitution tokens:

                    {cwd} — absolute path of the session's working directory
                    {claude} — `claude` (or `claude --resume <id>` on resume)
                    {command} — full shell line: `cd '<cwd>' && {claude}`

                    Most CLI terminals accept `--working-directory` and `-e`, so a typical entry looks like: ["--working-directory={cwd}", "-e", "{claude}"]
                    """
                ) {
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
                                .help("Remove argument")
                            }
                        }
                        Button {
                            arguments.append("")
                        } label: {
                            Label("Add Argument", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            field(
                label: "Fallback Icon (SF Symbol)",
                helpText: "Used only if the hub can't resolve the host app's actual icon (i.e. no Bundle Identifier set, or the app isn't installed). Otherwise the live icon shown above is what the user sees."
            ) {
                HStack {
                    TextField("e.g. terminal.fill", text: $icon)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
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
        .frame(width: 560)
        .onAppear { loadFromEditing() }
    }

    @ViewBuilder
    private func field<Content: View>(
        label: String,
        helpText: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let helpText {
                    HelpPopover(text: helpText)
                }
            }
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

    /// Opens the standard NSOpenPanel and lets the user pick either:
    ///   - an .app bundle → we extract its executable + bundleIdentifier
    ///     from Info.plist, fill them in, and the icon preview updates
    ///     automatically via NSWorkspace.icon(forFile:)
    ///   - a plain executable → we use its path verbatim
    ///
    /// `treatsFilePackagesAsDirectories = false` is what makes .app bundles
    /// selectable as files instead of opening into them like directories.
    private func browseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.title = "Select host application or executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if url.pathExtension == "app", let bundle = Bundle(url: url) {
            if let exeURL = bundle.executableURL {
                executable = exeURL.path
            } else {
                executable = url.path
            }
            // Always overwrite bundleIdentifier when selecting an .app —
            // that's the most reliable source. The user can clear/edit
            // afterwards if they have reason to.
            if let bundleID = bundle.bundleIdentifier {
                bundleIdentifier = bundleID
            }
        } else {
            executable = url.path
        }
    }
}
