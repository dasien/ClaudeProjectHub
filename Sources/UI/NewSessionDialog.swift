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

    /// Distinct host windows of `runningSessions`, grouped by
    /// `hostWindowID`. The picker uses these instead of raw sessions so
    /// that N tabs in one iTerm2 window collapse to one row — picking
    /// any of them produces the same windowID at launch time, and the
    /// previous per-session listing made the choice look meaningful
    /// when it wasn't. Each group's `representativeSessionID` is the
    /// most-recently-active session in the window; the launcher maps
    /// it back to the same windowID, so behavior is unchanged.
    private struct WindowGroup: Identifiable {
        let id: CGWindowID
        let sessions: [Session]
        var representativeSessionID: Session.ID { sessions.first!.id }
        var displayLabel: String {
            sessions.map(\.displayTitle).joined(separator: ", ")
        }
    }

    private var runningWindows: [WindowGroup] {
        let grouped = Dictionary(grouping: runningSessions) { $0.hostWindowID }
        return grouped.compactMap { (windowID, sessions) -> WindowGroup? in
            guard let windowID, !sessions.isEmpty else { return nil }
            let sorted = sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
            return WindowGroup(id: windowID, sessions: sorted)
        }
        .sorted {
            ($0.sessions.first?.lastActivityAt ?? .distantPast)
                > ($1.sessions.first?.lastActivityAt ?? .distantPast)
        }
    }

    private var canUseNewTab: Bool {
        (selectedHost?.supportsNewTab ?? false) && !runningWindows.isEmpty
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
                       !runningWindows.contains(where: { $0.representativeSessionID == target }) {
                        targetSessionID = nil
                    }
                    if windowMode == .newTab, !canUseNewTab {
                        windowMode = .newWindow
                    }
                    if windowMode == .newTab,
                       targetSessionID == nil,
                       runningWindows.count == 1 {
                        targetSessionID = runningWindows.first?.representativeSessionID
                    }
                }
            }

            field(label: "Open in") {
                if isHostRunning {
                    // Custom radio rows instead of `Picker(.radioGroup)`
                    // so the "New tab…" option can stay visible-but-
                    // disabled when the host doesn't support tabs or
                    // has no existing windows. SwiftUI's radio-group
                    // Picker doesn't let us disable individual options.
                    VStack(alignment: .leading, spacing: 6) {
                        radioOption(
                            value: .newWindow,
                            label: WindowMode.newWindow.displayName
                        )
                        radioOption(
                            value: .newTab,
                            label: "New tab in an existing window…"
                        )
                        .disabled(!canUseNewTab)
                        .opacity(canUseNewTab ? 1.0 : 0.4)
                        .help(newTabDisabledReason)
                    }

                    if windowMode == .newTab {
                        Picker("", selection: $targetSessionID) {
                            Text("Choose a window…").tag(Session.ID?.none)
                            ForEach(runningWindows) { window in
                                Text(window.displayLabel)
                                    .tag(Session.ID?.some(window.representativeSessionID))
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

    /// One radio row in the Open-in chooser. We build these by hand
    /// instead of using `Picker(.radioGroup)` so individual options
    /// can be disabled — the "New tab…" option needs to stay visible
    /// when the host doesn't support tabs (or has no open windows yet),
    /// rather than disappearing and shifting the layout around.
    @ViewBuilder
    private func radioOption(value: WindowMode, label: String) -> some View {
        Button {
            windowMode = value
            // Same auto-pick the previous Picker.onChange did: if the
            // user flips to newTab and there's exactly one candidate
            // window, pre-select it so they don't have to dig into the
            // dropdown.
            if value == .newTab,
               targetSessionID == nil,
               runningWindows.count == 1 {
                targetSessionID = runningWindows.first?.representativeSessionID
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: windowMode == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(windowMode == value ? Color.accentColor : .secondary)
                Text(label)
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Help tooltip for the "New tab…" row when it's disabled. Two
    /// distinct cases worth surfacing: host can't do tabs at all, vs.
    /// host can but has nothing to add to.
    private var newTabDisabledReason: String {
        if canUseNewTab { return "" }
        let hostName = selectedHost?.displayName ?? "This host"
        if !(selectedHost?.supportsNewTab ?? false) {
            return "\(hostName) doesn't support adding a tab to an existing window."
        }
        return "No \(hostName) windows are open to add a tab to."
    }

    private func browseForDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
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
