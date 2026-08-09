import Foundation

/// Circadian ("natural light") schedule: maps the time of day to a target
/// main-light (brightness, color temperature) pair, linearly interpolated
/// between anchor points so the light drifts smoothly through the day
/// (sunrise → noon → evening → night), similar to Hue's Natural Light.
struct CircadianSchedule: Equatable {
    struct Anchor: Equatable {
        /// Minutes since midnight at which the target applies exactly.
        let minutes: Int
        let bright: Int
        let ct: Int
    }

    let anchors: [Anchor]

    /// Default full-day schedule.
    static let `default` = CircadianSchedule(anchors: [
        Anchor(minutes: 6 * 60, bright: 45, ct: 2700),   // 06:00 日出
        Anchor(minutes: 9 * 60, bright: 85, ct: 5500),   // 09:00 上午
        Anchor(minutes: 12 * 60, bright: 100, ct: 6500), // 12:00 正午峰值
        Anchor(minutes: 17 * 60, bright: 80, ct: 5000),  // 17:00 下午
        Anchor(minutes: 20 * 60, bright: 55, ct: 3500),  // 20:00 傍晚
        Anchor(minutes: 23 * 60, bright: 25, ct: 2700),  // 23:00 夜间
    ])

    /// Device protocol ranges for the main light.
    static let brightRange = 1...100
    static let ctRange = 1700...6500

    /// Target for the given moment, using the current calendar's wall clock.
    func target(at date: Date) -> (bright: Int, ct: Int) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return target(minutesSinceMidnight: minutes)
    }

    /// Target for a minute-of-day (0...1439). Wraps around midnight: times
    /// before the first anchor interpolate between the last and first anchor.
    func target(minutesSinceMidnight minutes: Int) -> (bright: Int, ct: Int) {
        let sorted = anchors.sorted { $0.minutes < $1.minutes }
        guard let first = sorted.first else { return (50, 4000) }
        guard let last = sorted.last else { return (50, 4000) }
        let minute = ((minutes % 1440) + 1440) % 1440

        // Default to the wrap interval (last anchor → first anchor).
        var lower = last
        var upper = first
        for anchor in sorted where anchor.minutes <= minute {
            lower = anchor
            if let next = sorted.first(where: { $0.minutes > minute }) {
                upper = next
            }
        }

        let span = (upper.minutes - lower.minutes + 1440) % 1440
        let progress: Double
        if span == 0 {
            progress = 0
        } else {
            let elapsed = (minute - lower.minutes + 1440) % 1440
            progress = Double(elapsed) / Double(span)
        }

        let bright = Self.interpolate(lower.bright, upper.bright, progress)
        let ct = Self.interpolate(lower.ct, upper.ct, progress)
        return (Self.clamp(bright, to: Self.brightRange), Self.clamp(ct, to: Self.ctRange))
    }

    // MARK: - Helpers

    private static func interpolate(_ a: Int, _ b: Int, _ progress: Double) -> Int {
        Int((Double(a) + (Double(b) - Double(a)) * progress).rounded())
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
