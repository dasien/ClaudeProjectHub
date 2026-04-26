import Foundation

enum SessionStatus: String, Codable {
    case running
    case closed
}

extension SessionStatus {
    var sortRank: Int {
        switch self {
        case .running: return 0
        case .closed: return 1
        }
    }
}
