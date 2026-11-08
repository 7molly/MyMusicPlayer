import Foundation

/// Режим повтора треков
enum RepeatMode: Int, CaseIterable, Identifiable, Codable {
    case off = 0
    case all = 1
    case one = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Выкл"
        case .all: return "Повторять все"
        case .one: return "Повторять один"
        }
    }

    var iconName: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    /// Циклическое переключение режима
    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}
