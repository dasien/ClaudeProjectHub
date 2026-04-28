import AppKit
import SwiftUI

/// Sheet for adding or editing a host. The host's launch behavior lives
/// entirely in its `.applescript` file on disk — this editor just
/// captures the metadata that links a session to that file.
struct HostEditorView: View {
    @EnvironmentObject private var hostRegistry: HostRegistry
    @Environment(\.dismiss) private var dismiss

    /// nil when creating a new host; populated when editing an existing one.
    let editingHost: HostConfig?

    @State private var id: String = ""
    @State private var displayName: String = ""
    @State private var bundleIdentifier: String = ""
    @State private var launchScript: String = ""
    /// Tracks whether the user has manually edited `id` or `launchScript`.
    /// Once they have, we stop overwriting their text from `displayName`
    /// changes — auto-fill is a convenience, not a takeover.
    @State private var idManuallyEdited = false
    @State private var launchScriptManuallyEdited = false

    private var isEditing: Bool { editingHost != nil }

    private var canSave: Bool {
        guard !id.trimmingCharacters(in: .whitespaces).isEmpty,
              !displayName.trimmingCharacters(in: .whitespaces).isEmpty,
              !launchScript.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if !hostRegistry.isIDAvailable(id, excluding: editingHost?.id) { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                EditorIconPreview(bundleIdentifier: bundleIdentifier, size: 32)
                Text(isEditing ? "Edit Host" : "New Host")
                    .font(.headline)
            }

            field(label: "Display Name") {
                TextField("e.g. Ghostty", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: displayName) { _, newValue in
                        if !idManuallyEdited {
                            id = slugify(newValue)
                        }
                        if !launchScriptManuallyEdited {
                            launchScript = "\(slugify(newValue)).applescript"
                        }
                    }
            }

            field(
                label: "Application",
                helpText: "Pick the host app. Sets the bundle identifier (used to locate the running process and resolve the icon shown above) and prefills the display name when blank."
            ) {
                HStack {
                    TextField("com.example.host", text: $bundleIdentifier)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseApplication)
                }
            }

            field(
                label: "Identifier",
                helpText: "A unique key sessions store to remember which host they were launched in. Once a host is created, this can't change without orphaning existing sessions."
            ) {
                TextField("e.g. ghostty", text: $id)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditing)
                    .onChange(of: id) { _, newValue in
                        // Distinguish "auto-filled from displayName" from
                        // "user typed in this field" by comparing against
                        // the slugified displayName. Without this guard,
                        // auto-fill from a single keystroke would mark the
                        // field as manually edited and stop subsequent
                        // displayName changes from propagating.
                        if !isEditing, newValue != slugify(displayName) {
                            idManuallyEdited = true
                        }
                    }
            }

            field(
                label: "Launch Script",
                helpText: """
                Filename inside ~/Library/Application Support/ClaudeProjectHub/scripts/. The script does the actual launching — substitutions {cwd}, {claude}, {marker}, {mode}, and {targetWindowID} are replaced before it runs.

                On Add, if the file doesn't exist yet, it's created from _template.applescript so you have a starting point to edit.
                """
            ) {
                HStack {
                    TextField("e.g. ghostty.applescript", text: $launchScript)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: launchScript) { _, newValue in
                            // Same trick as the identifier field — only
                            // treat the change as manual if it doesn't
                            // match what auto-fill would have produced.
                            if newValue != "\(slugify(displayName)).applescript" {
                                launchScriptManuallyEdited = true
                            }
                        }
                    if isEditing {
                        Button("Reveal in Finder", action: revealScript)
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
        .frame(width: 520)
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
        bundleIdentifier = host.bundleIdentifier ?? ""
        launchScript = host.launchScript
        // Existing values shouldn't get clobbered by displayName edits.
        idManuallyEdited = true
        launchScriptManuallyEdited = true
    }

    private func save() {
        let host = HostConfig(
            id: id.trimmingCharacters(in: .whitespaces),
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            bundleIdentifier: {
                let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }(),
            launchScript: launchScript.trimmingCharacters(in: .whitespaces)
        )
        if isEditing {
            hostRegistry.update(host)
        } else {
            hostRegistry.add(host)
        }
        dismiss()
    }

    /// Opens an NSOpenPanel rooted at /Applications. Picking an .app fills
    /// in the bundle identifier from its Info.plist and prefills the
    /// display name when blank. `treatsFilePackagesAsDirectories = false`
    /// is what makes .app bundles selectable instead of being treated as
    /// folders.
    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.title = "Choose host application"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url) else { return }

        if let bundleID = bundle.bundleIdentifier {
            bundleIdentifier = bundleID
        }
        // Prefill display name only when blank — never overwrite text the
        // user has already typed.
        if displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            let appName = url.deletingPathExtension().lastPathComponent
            displayName = appName
            // Trigger the slugify side-effects since onChange doesn't fire
            // for programmatic assigns when the value is identical (it
            // does fire here because we just set from empty).
        }
    }

    private func revealScript() {
        guard let host = editingHost,
              let scriptURL = hostRegistry.scriptURL(forID: host.id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([scriptURL])
    }

    /// Lowercased, dashes-only slug suitable for both the host id and the
    /// default launch script filename. Strips diacritics, collapses
    /// non-alphanumerics into single dashes, trims leading/trailing dashes.
    private func slugify(_ source: String) -> String {
        let folded = source.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        var result = ""
        var lastWasDash = false
        for char in folded {
            if char.isLetter || char.isNumber {
                result.append(char)
                lastWasDash = false
            } else if !lastWasDash && !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }
}
