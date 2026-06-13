import AppKit
import SwiftUI

/// Sheet for resuming a historical (closed, non-hub-launched) claude
/// session. The user picks a host and window mode; `adoptHistorical`
/// creates a closed Session record then runs the standard resume flow
/// against the chosen host.
///
/// Historical sessions carry no host affinity (the per-pid sessions
/// file is long gone and the JSONL doesn't record which host launched
/// it), so the host picker is required — there's no sensible default
/// other than the user's last choice.
struct HistoricalResumeDialog: View {
    let historical: HistoricalSession

    @EnvironmentObject private var launcher: SessionLauncherService
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var hostRegistry: HostRegistry
    @EnvironmentObject private var historicalScanner: HistoricalSessionScanner
    @Environment(\.dismiss) private var dismiss

    @State private var hostID: String = "terminal-app"
    @State private var windowMode: WindowMode = .newWindow
    @State private var targetSessionID: Session.ID?
    @State private var isResuming = false

    private var selectedHost: HostConfig? {
        hostRegistry.host(forID: hostID)
    }

    /// Mirrors `NewSessionDialog.installedHosts` — only list hosts
    /// whose app is actually installed.
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

    private var runningSessions: [Session] {
        store.sessions
            .filter { $0.status.isRunning && $0.hostID == hostID }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private var isHostRunning: Bool {
        guard let bundleID = selectedHost?.bundleIdentifier else { return false }
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID
        }
    }

    private var canUseNewTab: Bool {
        (selectedHost?.supportsNewTab ?? false) && isHostRunning && !runningSessions.isEmpty
    }

    private var canResume: Bool {
        guard !isResuming, selectedHost != nil else { return false }
        if windowMode == .newTab && targetSessionID == nil { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resume Session").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(historical.cwd.lastPathComponent)
                    .font(.body)
                Text(historical.cwd.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let summary = historical.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
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
                    if let target = targetSessionID,
                       !runningSessions.contains(where: { $0.id == target }) {
                        targetSessionID = nil
                    }
                    if windowMode == .newTab, !canUseNewTab {
                        windowMode = .newWindow
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
                            ForEach(runningSessions) { s in
                                Text(s.displayTitle).tag(Session.ID?.some(s.id))
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
                Button("Resume") { startResume() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canResume)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
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

    private func startResume() {
        isResuming = true
        let mode = isHostRunning ? windowMode : .newWindow
        let target = (mode == .newTab) ? targetSessionID : nil
        Task {
            let success = await launcher.adoptHistorical(
                historical,
                hostID: hostID,
                windowMode: mode,
                targetSessionID: target
            )
            isResuming = false
            // Always refresh the scanner — on success the row should
            // disappear (the sessionId is now tracked); on failure the
            // adopted closed Session row is in the main list, and the
            // historical row should clear too so the user isn't shown
            // duplicates.
            historicalScanner.refresh()
            if success {
                dismiss()
            }
        }
    }
}
