import AppKit
import SwiftUI

struct NewSessionDialog: View {
    @EnvironmentObject private var launcher: SessionLauncherService
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var hostRegistry: HostRegistry
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var cwd: URL?
    @State private var hostID: String = "terminal-app"
    @State private var windowMode: WindowMode = .newWindow
    @State private var targetSessionID: Session.ID?
    @State private var isLaunching = false
    @FocusState private var nameFocused: Bool

    private var selectedHost: HostConfig? {
        hostRegistry.host(forID: hostID)
    }

    /// Only hosts whose app is actually installed on this machine.
    /// We pre-ship many JetBrains IDE hosts in the defaults; without
    /// this filter the picker would list all of them even for users
    /// who only have one or two installed. Hosts without a bundle id
    /// (rare) are always shown.
    private var installedHosts: [HostConfig] {
        hostRegistry.hosts.filter { host in
            guard let bundleID = host.bundleIdentifier, !bundleID.isEmpty else {
                return true
            }
            return NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleID
            ) != nil
        }
    }

    /// Only sessions running in the currently-selected host. A new tab can
    /// only nest in a window that belongs to the same app — picking a
    /// Terminal target while launching iTerm2 wouldn't work.
    private var runningSessions: [Session] {
        store.sessions
            .filter { $0.status.isRunning && $0.hostID == hostID }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private var canUseNewTab: Bool {
        (selectedHost?.supportsNewTab ?? false) && !runningSessions.isEmpty
    }

    private var canLaunch: Bool {
        guard cwd != nil, !isLaunching else { return false }
        if windowMode == .newTab && targetSessionID == nil { return false }
        return true
    }

    private var isHostRunning: Bool {
        guard let bundleID = selectedHost?.bundleIdentifier else { return false }
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID
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

            field(label: "Host") {
                Picker("", selection: $hostID) {
                    ForEach(installedHosts) { host in
                        Text(host.displayName).tag(host.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: hostID) { _, _ in
                    // Sessions that don't belong to the new host should
                    // disappear from the dropdown — clear any selection
                    // that's now invalid, and fall back to .newWindow if
                    // the new host can't use tabs at all.
                    if let target = targetSessionID,
                       !runningSessions.contains(where: { $0.id == target }) {
                        targetSessionID = nil
                    }
                    if windowMode == .newTab, !canUseNewTab {
                        windowMode = .newWindow
                    }
                    if windowMode == .newTab,
                       targetSessionID == nil,
                       runningSessions.count == 1 {
                        targetSessionID = runningSessions.first?.id
                    }
                }
            }

            field(label: "Open in") {
                if isHostRunning {
                    Picker("", selection: $windowMode) {
                        Text(WindowMode.newWindow.displayName).tag(WindowMode.newWindow)
                        if canUseNewTab {
                            Text("New tab in…").tag(WindowMode.newTab)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .onChange(of: windowMode) { _, newMode in
                        if newMode == .newTab,
                           targetSessionID == nil,
                           runningSessions.count == 1 {
                            targetSessionID = runningSessions.first?.id
                        }
                    }

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
                        .help("\(selectedHost?.displayName ?? "This host") isn't running, so a new window will be opened.")
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
        .onAppear {
            nameFocused = true
            // Default to the first installed host if our seed value
            // isn't installed on this machine, or isn't in the
            // registry at all (e.g. user removed terminal-app from
            // hosts.json).
            if !installedHosts.contains(where: { $0.id == hostID }) {
                if let first = installedHosts.first {
                    hostID = first.id
                }
            }
        }
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
        let mode = isHostRunning ? windowMode : .newWindow
        let target = (mode == .newTab) ? targetSessionID : nil
        Task {
            let success = await launcher.launch(
                name: name,
                cwd: cwd,
                hostID: hostID,
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
