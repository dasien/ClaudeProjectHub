import AppKit
import SwiftUI

struct ResumeSessionDialog: View {
    let session: Session
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var launcher: SessionLauncherService
    @Environment(\.dismiss) private var dismiss

    @State private var windowMode: WindowMode = .newWindow
    @State private var targetSessionID: Session.ID?
    @State private var isResuming = false

    private var runningSessions: [Session] {
        // Exclude this session itself in case it's somehow running.
        store.sessions
            .filter { $0.status.isRunning && $0.id != session.id }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private var isTerminalRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == HostKind.terminalApp.bundleIdentifier
        }
    }

    private var canUseNewTab: Bool { isTerminalRunning && !runningSessions.isEmpty }

    private var canResume: Bool {
        guard !isResuming else { return false }
        if windowMode == .newTab && targetSessionID == nil { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resume Session").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.body)
                Text(session.cwd.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Open in").font(.subheadline).foregroundStyle(.secondary)
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
                        .help("Terminal isn't running, so a new window will be opened.")
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
    }

    private func startResume() {
        isResuming = true
        let mode = isTerminalRunning ? windowMode : .newWindow
        let target = (mode == .newTab) ? targetSessionID : nil
        Task {
            let success = await launcher.resume(
                session,
                windowMode: mode,
                targetSessionID: target
            )
            isResuming = false
            if success {
                dismiss()
            }
        }
    }
}
