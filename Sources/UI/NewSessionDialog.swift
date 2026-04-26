import AppKit
import SwiftUI

struct NewSessionDialog: View {
    @EnvironmentObject private var launcher: SessionLauncherService
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var cwd: URL?
    @State private var windowMode: WindowMode = .newWindow
    @State private var targetSessionID: Session.ID?
    @State private var isLaunching = false
    @FocusState private var nameFocused: Bool

    private var runningSessions: [Session] {
        store.sessions
            .filter { $0.status == .running }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private var canUseNewTab: Bool { !runningSessions.isEmpty }

    private var canLaunch: Bool {
        guard cwd != nil, !isLaunching else { return false }
        if windowMode == .newTab && targetSessionID == nil { return false }
        return true
    }

    private var isTerminalRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == HostKind.terminalApp.bundleIdentifier
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Session").font(.headline)

            field(label: "Name") {
                TextField("Optional, defaults to directory name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }

            field(label: "Directory") {
                HStack {
                    Text(cwd?.path ?? "Not selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(cwd == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Browse…", action: browseForDirectory)
                }
            }

            field(label: "Open in") {
                if isTerminalRunning {
                    Picker("", selection: $windowMode) {
                        Text(WindowMode.newWindow.displayName).tag(WindowMode.newWindow)
                        if canUseNewTab {
                            Text("New tab in…").tag(WindowMode.newTab)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if windowMode == .newTab {
                        Picker("", selection: $targetSessionID) {
                            Text("Choose a session…").tag(Session.ID?.none)
                            ForEach(runningSessions) { session in
                                Text(session.displayTitle).tag(Session.ID?.some(session.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .padding(.leading, 20)
                    }
                } else {
                    Text(WindowMode.newWindow.displayName)
                        .foregroundStyle(.secondary)
                        .help("Terminal isn't running yet, so a new window will be opened.")
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Launch") { launch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canLaunch)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { nameFocused = true }
    }

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
    }

    private func browseForDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose a directory for the new Claude session"
        panel.prompt = "Select"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        cwd = url
        if name.isEmpty {
            name = url.lastPathComponent
        }
    }

    private func launch() {
        guard let cwd = cwd else { return }
        isLaunching = true
        let mode = isTerminalRunning ? windowMode : .newWindow
        let target = (mode == .newTab) ? targetSessionID : nil
        Task {
            let success = await launcher.launch(
                name: name,
                cwd: cwd,
                hostKind: .terminalApp,
                windowMode: mode,
                targetSessionID: target
            )
            isLaunching = false
            if success {
                dismiss()
            }
        }
    }
}
