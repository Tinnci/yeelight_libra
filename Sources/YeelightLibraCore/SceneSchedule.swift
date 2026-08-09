import Foundation

/// One scheduled scene slot: apply `sceneName` once per day at a daily time.
struct SceneScheduleEntry: Codable, Equatable, Identifiable {
    let id: Int
    var hour: Int
    var minute: Int
    var sceneName: String
    var enabled: Bool

    var minutesSinceMidnight: Int { hour * 60 + minute }
}

/// A fixed set of daily scene slots (up to 4).
struct SceneSchedule: Codable, Equatable {
    var entries: [SceneScheduleEntry]

    static func defaultSchedule() -> SceneSchedule {
        SceneSchedule(entries: [
            SceneScheduleEntry(id: 0, hour: 19, minute: 0, sceneName: ScenePreset.reading.name, enabled: false),
            SceneScheduleEntry(id: 1, hour: 23, minute: 0, sceneName: ScenePreset.sleep.name, enabled: false),
            SceneScheduleEntry(id: 2, hour: 8, minute: 0, sceneName: ScenePreset.focus.name, enabled: false),
            SceneScheduleEntry(id: 3, hour: 21, minute: 0, sceneName: ScenePreset.relax.name, enabled: false),
        ])
    }

    /// True when the entry is enabled, its daily time has passed at `date`,
    /// and it has not already been applied on `appliedDay` (a start-of-day
    /// date, or nil when it has never been applied).
    func isDue(_ entry: SceneScheduleEntry, at date: Date, appliedOn appliedDay: Date?, calendar: Calendar) -> Bool {
        guard entry.enabled else { return false }
        if let appliedDay, calendar.isDate(appliedDay, inSameDayAs: date) { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let nowMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return entry.minutesSinceMidnight <= nowMinutes
    }

    /// Returns all due entries in chronological order. Stable ordering is
    /// important when the app starts after several slots have already passed.
    func dueEntries(
        at date: Date,
        appliedDays: [Int: Date],
        calendar: Calendar
    ) -> [SceneScheduleEntry] {
        entries
            .filter { isDue($0, at: date, appliedOn: appliedDays[$0.id], calendar: calendar) }
            .sorted {
                if $0.minutesSinceMidnight == $1.minutesSinceMidnight {
                    return $0.id < $1.id
                }
                return $0.minutesSinceMidnight < $1.minutesSinceMidnight
            }
    }
}
