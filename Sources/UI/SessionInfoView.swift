import AppKit
import SwiftUI

/// "Get Info" popout window for a single session. Shows the
/// session's metadata and parses its JSONL transcript to compute
/// total cost + token usage. Right-click → Get Info opens this in a
/// new SwiftUI window via `WindowGroup(id:for:)`.
struct SessionInfoView: View {
    let sessionID: Session.ID
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var hostRegistry: HostRegistry
    @EnvironmentObject private var pricingRegistry: ModelPricingRegistry

    @State private var usage: SessionUsage?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var showNoTranscriptAlert = false

    private var session: Session? {
        store.sessions.first(where: { $0.id == sessionID })
    }

    var body: some View {
        Group {
            if let session {
                content(for: session)
            } else {
                Text("Session not found")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
        .frame(minHeight: 360)
        .task(id: sessionID) {
            await loadUsage()
        }
        .alert("No transcript yet", isPresented: $showNoTranscriptAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Claude only writes the conversation file once the first message is exchanged, and this session hasn't sent anything yet.")
        }
    }

    @ViewBuilder
    private func content(for session: Session) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(for: session)
                Divider()
                metadataSection(for: session)
                Divider()
                usageSection
            }
            .padding(20)
            // Everything here is a value worth pasting elsewhere — paths,
            // the session id, token counts. Buttons and the like are
            // unaffected; only Text picks this up.
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(for session: Session) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let host = hostRegistry.host(forID: session.hostID) {
                HostIconView(host: host, size: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                HStack(spacing: 4) {
                    Text(session.cwd.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        revealInFinder(session.cwd)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Open project folder in Finder")
                }
            }
            Spacer()
        }
    }

    private func metadataSection(for session: Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row(label: "Host", value: hostRegistry.displayName(forID: session.hostID))
            row(label: "Status", value: statusText(session.status))
            if let claudeSessionId = session.claudeSessionId {
                claudeSessionIDRow(claudeSessionId: claudeSessionId, cwd: session.cwd)
            }
            row(
                label: "Created",
                value: session.createdAt.formatted(date: .abbreviated, time: .shortened)
            )
            row(
                label: "Last Activity",
                value: session.lastActivityAt.formatted(date: .abbreviated, time: .shortened)
            )
        }
    }

    /// Specialized row for the Claude session ID with a "Show in
    /// Finder" button that reveals the underlying JSONL transcript.
    /// If the JSONL doesn't exist yet (no message exchanged), show
    /// an alert explaining why — same pattern as the Resume flow's
    /// "no conversation to resume" guard in SessionLauncherService.
    private func claudeSessionIDRow(claudeSessionId: String, cwd: URL) -> some View {
        let jsonlURL = ClaudeSessionTranscript.jsonlURL(for: cwd, claudeSessionId: claudeSessionId)
        return HStack(alignment: .firstTextBaseline) {
            Text("Claude Session ID")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(claudeSessionId)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                if FileManager.default.fileExists(atPath: jsonlURL.path) {
                    revealInFinder(jsonlURL)
                } else {
                    showNoTranscriptAlert = true
                }
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Reveal transcript JSONL in Finder")
            Spacer()
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage & Cost")
                .font(.headline)

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading transcript…").foregroundStyle(.secondary)
                }
            } else if let loadError {
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let usage, !usage.byModel.isEmpty {
                usageDetails(usage)
            } else {
                Text("No transcript yet — usage will appear after the first message.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func usageDetails(_ usage: SessionUsage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Zero-token entries aren't usage. Claude Code records
            // locally-fabricated messages under the model id
            // "<synthetic>" — "No response requested.", "Prompt is too
            // long" — with every token count at 0 and no service tier,
            // because no request was made. Listing them invites the
            // question of why they have no cost.
            ForEach(usage.byModel.keys.sorted().filter { (usage.byModel[$0]?.totalTokens ?? 0) > 0 }, id: \.self) { modelID in
                if let totals = usage.byModel[modelID] {
                    modelLine(modelID: modelID, totals: totals)
                }
            }
            Divider().padding(.vertical, 4)
            row(
                label: "Total Tokens",
                value: usage.totalTokens.formatted(.number)
            )
            let unpriced = usage.unpricedModels(using: pricingRegistry)
            row(
                label: unpriced.isEmpty ? "Total Cost" : "Total Cost (partial)",
                value: usage.totalCost(using: pricingRegistry).formatted(
                    .currency(code: pricingRegistry.table.metadata.currency ?? "USD")
                )
            )
            row(
                label: "Pricing as of",
                value: pricingRegistry.table.metadata.asOf,
                muted: true
            )
            if !unpriced.isEmpty {
                // Say so rather than quietly omitting them — a confident
                // total that silently drops a model is worse than no total.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(unpricedWarning(unpriced))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
    }

    private func unpricedWarning(_ unpriced: [(modelID: String, tokens: Int)]) -> String {
        let names = unpriced.map(\.modelID).joined(separator: ", ")
        let tokens = unpriced.reduce(0) { $0 + $1.tokens }.formatted(.number)
        return "Cost excludes \(tokens) tokens on \(names) — no pricing entry. "
            + "Add one to models.json in the app's support folder to include it."
    }

    private func modelLine(modelID: String, totals: SessionUsage.ModelTotals) -> some View {
        let entry = pricingRegistry.pricing(forModel: modelID)
        let modelDisplay = entry?.displayName ?? modelID
        let cost = entry?.pricing.cost(
            inputTokens: totals.inputTokens,
            outputTokens: totals.outputTokens,
            cacheWrite5mTokens: totals.cacheWrite5mTokens,
            cacheWrite1hTokens: totals.cacheWrite1hTokens,
            cacheReadTokens: totals.cacheReadTokens
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(modelDisplay)
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                if let cost {
                    Text(cost.formatted(.currency(code: pricingRegistry.table.metadata.currency ?? "USD")))
                        .font(.callout)
                        .monospacedDigit()
                } else {
                    Text("no pricing")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(tokenSummary(totals))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func tokenSummary(_ t: SessionUsage.ModelTotals) -> String {
        var parts: [String] = []
        parts.append("in \(t.inputTokens.formatted(.number))")
        parts.append("out \(t.outputTokens.formatted(.number))")
        if t.cacheWrite5mTokens > 0 || t.cacheWrite1hTokens > 0 {
            let totalWrite = t.cacheWrite5mTokens + t.cacheWrite1hTokens
            parts.append("cache write \(totalWrite.formatted(.number))")
        }
        if t.cacheReadTokens > 0 {
            parts.append("cache read \(t.cacheReadTokens.formatted(.number))")
        }
        return parts.joined(separator: " · ")
    }

    private func statusText(_ status: SessionStatus) -> String {
        switch status {
        case .working: return "Working"
        case .idle: return "Idle"
        case .closed: return "Closed"
        }
    }

    @ViewBuilder
    private func row(label: String, value: String, monospaced: Bool = false, muted: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.callout)
                .foregroundStyle(muted ? .tertiary : .primary)
                .modifier(MonospacedIf(monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    /// Open the URL in Finder. For directories, opens the directory
    /// itself; for files, reveals the file in its parent folder.
    ///
    /// Implemented by shelling out to `/usr/bin/open` rather than
    /// using `NSWorkspace.activateFileViewerSelecting`. The
    /// NSWorkspace API drives Apple's internal Powerbox / sandbox-
    /// extension flow, which logs noisy "client lacks entitlements"
    /// warnings — and sometimes silently fails — for paths outside
    /// the standard user-selected zones (e.g. anything under
    /// `~/.claude/`). `open` is a separate process with no such
    /// constraints since the hub isn't sandboxed.
    private func revealInFinder(_ url: URL) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if exists, isDir.boolValue {
            task.arguments = [url.path]
        } else {
            task.arguments = ["-R", url.path]
        }
        try? task.run()
    }

    private func loadUsage() async {
        guard let session,
              let claudeSessionId = session.claudeSessionId else {
            isLoading = false
            usage = SessionUsage()
            return
        }
        let url = ClaudeSessionTranscript.jsonlURL(
            for: session.cwd,
            claudeSessionId: claudeSessionId
        )
        // Run the parse off the main actor — large transcripts can
        // take a beat to chew through.
        let result = await Task.detached(priority: .userInitiated) {
            do {
                return Result<SessionUsage, Error>.success(try ClaudeSessionTranscript.parse(jsonlURL: url))
            } catch {
                return Result<SessionUsage, Error>.failure(error)
            }
        }.value
        switch result {
        case .success(let parsed):
            usage = parsed
            loadError = nil
        case .failure:
            // Most likely the transcript file just doesn't exist
            // yet (session has no exchanged messages). Treat as
            // "no usage" rather than a hard error.
            usage = SessionUsage()
            loadError = nil
        }
        isLoading = false
    }
}

private struct MonospacedIf: ViewModifier {
    let active: Bool
    init(_ active: Bool) { self.active = active }
    func body(content: Content) -> some View {
        if active {
            content.font(.system(.callout, design: .monospaced))
        } else {
            content
        }
    }
}
