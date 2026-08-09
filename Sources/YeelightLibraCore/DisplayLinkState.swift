import Foundation

/// Small state machine used to invalidate stale display transitions.
struct DisplayLinkState: Equatable {
    private(set) var generation = 0
    private(set) var sleeping = false

    mutating func beginSleep() -> Int {
        generation += 1
        sleeping = true
        return generation
    }

    mutating func beginWake() -> Int {
        generation += 1
        sleeping = false
        return generation
    }

    mutating func stop() {
        generation += 1
        sleeping = false
    }

    func owns(_ candidate: Int) -> Bool { candidate == generation }
}
