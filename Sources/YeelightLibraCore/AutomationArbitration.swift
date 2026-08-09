import Foundation

/// Automatic modes that compete for ownership of one or both light zones.
enum AutomationMode: Hashable {
    case cinema
    case circadian
    case screenSync
    case wakeUp
}

enum AutomationIntent: Equatable {
    case set(AutomationMode, enabled: Bool)
    case manualMainControl
    case manualBacklightControl
}

/// Pure conflict policy for automatic light ownership. Side effects remain in
/// AutoModeController; this module decides only which modes may remain active.
struct AutomationArbitration: Equatable {
    private(set) var active: Set<AutomationMode> = []

    mutating func apply(_ intent: AutomationIntent) -> Set<AutomationMode> {
        let before = active
        switch intent {
        case .set(let mode, enabled: false):
            active.remove(mode)
        case .set(let mode, enabled: true):
            active.insert(mode)
            switch mode {
            case .cinema:
                active.subtract([.circadian, .screenSync, .wakeUp])
            case .circadian:
                active.subtract([.cinema, .wakeUp])
            case .screenSync:
                active.remove(.cinema)
            case .wakeUp:
                active.subtract([.cinema, .circadian])
            }
        case .manualMainControl:
            active.subtract([.cinema, .circadian, .wakeUp])
        case .manualBacklightControl:
            active.subtract([.cinema, .screenSync])
        }
        return before.subtracting(active)
    }
}
