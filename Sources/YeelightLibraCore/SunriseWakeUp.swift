import Foundation

/// Daily sunrise wake-up schedule: over a configurable ramp window ending at
/// the alarm time, the main light ramps from warm/dim to a bright natural
/// target, ending fully on at the alarm time (Hue-style wake-up light).
struct SunriseWakeUp: Equatable {
    var alarmHour = 7
    var alarmMinute = 0
    var rampMinutes = 30

    var startBright = 1
    var startCT = 2700
    var endBright = 100
    var endCT = 5000

    enum Phase: Equatable {
        case awaiting
        case ramping
    }

    /// Alarm time on `day` (the date of `day` is used only to anchor the day).
    func windowEnd(on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: alarmHour, minute: alarmMinute, second: 0, of: day) ?? day
    }

    /// Ramp start = alarm time minus the ramp duration. Date math handles
    /// cross-midnight windows naturally (e.g. alarm 00:15 with 30-min ramp
    /// starts at 23:45 the previous day).
    func windowStart(on day: Date, calendar: Calendar) -> Date {
        let end = windowEnd(on: day, calendar: calendar)
        return calendar.date(byAdding: .minute, value: -rampMinutes, to: end) ?? end
    }

    /// The next relevant window relative to `date`, and the phase:
    /// - `.awaiting`: the window has not started yet on the returned day
    /// - `.ramping`: `date` is inside the window on the returned day
    /// After the window ends, the next occurrence is tomorrow (`.awaiting`).
    /// Cross-midnight windows (alarm before the ramp duration) are handled by
    /// anchoring on the window that actually contains `date`, so the pre-dawn
    /// part of the ramp is still reported as `.ramping`.
    func nextOccurrence(after date: Date, calendar: Calendar) -> (phase: Phase, day: Date) {
        let today = calendar.startOfDay(for: date)
        // If today's window already ended, the relevant window is tomorrow's
        // (it may already have started for cross-midnight alarms).
        let day: Date
        if date < windowEnd(on: today, calendar: calendar) {
            day = today
        } else {
            day = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        }
        let start = windowStart(on: day, calendar: calendar)
        let end = windowEnd(on: day, calendar: calendar)
        if date < start {
            return (.awaiting, day)
        } else if date < end {
            return (.ramping, day)
        } else {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            return (.awaiting, nextDay)
        }
    }

    /// Progress 0...1 while `date` is inside the window on `day`, nil outside.
    func progress(at date: Date, on day: Date, calendar: Calendar) -> Double? {
        let start = windowStart(on: day, calendar: calendar)
        let end = windowEnd(on: day, calendar: calendar)
        let total = end.timeIntervalSince(start)
        guard total > 0, date >= start, date < end else { return nil }
        return min(max(date.timeIntervalSince(start) / total, 0), 1)
    }

    /// Interpolated (brightness, color temperature) at a 0...1 progress.
    func target(progress: Double) -> (bright: Int, ct: Int) {
        let p = min(max(progress, 0), 1)
        return (
            Int((Double(startBright) + (Double(endBright) - Double(startBright)) * p).rounded()),
            Int((Double(startCT) + (Double(endCT) - Double(startCT)) * p).rounded())
        )
    }
}
