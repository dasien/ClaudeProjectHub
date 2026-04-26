import Foundation

enum DockState: Codable, Equatable {
    case docked(tabIndex: Int)
    case undocked
}
