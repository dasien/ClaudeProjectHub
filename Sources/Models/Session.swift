import Foundation
import CoreGraphics

struct Session: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String?
    var cwd: URL
    var hostKind: HostKind
    var claudeSessionId: String?
    var status: SessionStatus
    var pid: Int32?
    var hostWindowID: CGWindowID?
    var dockState: DockState
    var createdAt: Date
    var lastActivityAt: Date

    init(
        id: UUID = UUID(),
        name: String? = nil,
        cwd: URL,
        hostKind: HostKind,
        claudeSessionId: String? = nil,
        status: SessionStatus = .idle,
        pid: Int32? = nil,
        hostWindowID: CGWindowID? = nil,
        dockState: DockState = .docked(tabIndex: 0),
        createdAt: Date = Date(),
        lastActivityAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.hostKind = hostKind
        self.claudeSessionId = claudeSessionId
        self.status = status
        self.pid = pid
        self.hostWindowID = hostWindowID
        self.dockState = dockState
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
