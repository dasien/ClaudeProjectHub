import Foundation
import CoreGraphics

struct Session: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String?
    var cwd: URL
    /// References a HostConfig.id in the host registry (e.g. "terminal-app").
    /// String rather than enum so user-defined hosts loaded from
    /// hosts.json work without code changes.
    var hostID: String
    var claudeSessionId: String?
    var status: SessionStatus
    var pid: Int32?
    var hostWindowID: CGWindowID?
    var dockState: DockState
    /// Chosen at launch and reused on resume — a running session's TTL
    /// can't be changed, so this records what it was started with.
    var cacheTTL: PromptCacheTTL
    var createdAt: Date
    var lastActivityAt: Date

    init(
        id: UUID = UUID(),
        name: String? = nil,
        cwd: URL,
        hostID: String,
        claudeSessionId: String? = nil,
        status: SessionStatus = .idle,
        pid: Int32? = nil,
        hostWindowID: CGWindowID? = nil,
        dockState: DockState = .docked(tabIndex: 0),
        cacheTTL: PromptCacheTTL = .fiveMinutes,
        createdAt: Date = Date(),
        lastActivityAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.hostID = hostID
        self.claudeSessionId = claudeSessionId
        self.status = status
        self.pid = pid
        self.hostWindowID = hostWindowID
        self.dockState = dockState
        self.cacheTTL = cacheTTL
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }
}

extension Session {
    var displayTitle: String {
        if let name, !name.isEmpty { return name }
        return cwd.lastPathComponent
    }
    var displayPath: String { cwd.path }
}

// MARK: - Codable migration

extension Session {
    private enum CodingKeys: String, CodingKey {
        case id, name, cwd, hostID, hostKind, claudeSessionId, status, pid, hostWindowID, dockState, cacheTTL, createdAt, lastActivityAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        let cwd = try container.decode(URL.self, forKey: .cwd)
        // Pre-M6 records used `hostKind: HostKind` (an enum stringly encoded
        // as e.g. "terminal-app"). Accept either key for backwards compat;
        // the value is the same shape (a host id string) either way.
        let hostID = try container.decodeIfPresent(String.self, forKey: .hostID)
            ?? container.decodeIfPresent(String.self, forKey: .hostKind)
            ?? "terminal-app"
        let claudeSessionId = try container.decodeIfPresent(String.self, forKey: .claudeSessionId)
        let status = try container.decode(SessionStatus.self, forKey: .status)
        let pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        let hostWindowID = try container.decodeIfPresent(CGWindowID.self, forKey: .hostWindowID)
        let dockState = try container.decodeIfPresent(DockState.self, forKey: .dockState) ?? .docked(tabIndex: 0)
        // Absent on records written before the TTL picker existed; those
        // sessions were started without the env var, i.e. Claude Code's 5m default.
        let cacheTTL = try container.decodeIfPresent(PromptCacheTTL.self, forKey: .cacheTTL) ?? .fiveMinutes
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)

        self.init(
            id: id,
            name: name,
            cwd: cwd,
            hostID: hostID,
            claudeSessionId: claudeSessionId,
            status: status,
            pid: pid,
            hostWindowID: hostWindowID,
            dockState: dockState,
            cacheTTL: cacheTTL,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(hostID, forKey: .hostID)
        try container.encodeIfPresent(claudeSessionId, forKey: .claudeSessionId)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encodeIfPresent(hostWindowID, forKey: .hostWindowID)
        try container.encode(dockState, forKey: .dockState)
        try container.encode(cacheTTL, forKey: .cacheTTL)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastActivityAt, forKey: .lastActivityAt)
    }
}
