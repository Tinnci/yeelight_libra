import XCTest
@testable import YeelightLibraCore

final class SceneScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
    }

    func testDefaultScheduleHasFourSlots() {
        let schedule = SceneSchedule.defaultSchedule()
        XCTAssertEqual(schedule.entries.count, 4)
        XCTAssertEqual(schedule.entries.map(\.id), [0, 1, 2, 3])
        XCTAssertTrue(schedule.entries.allSatisfy { !$0.enabled })
        XCTAssertEqual(schedule.entries[0].hour, 19)
        XCTAssertEqual(schedule.entries[1].hour, 23)
        XCTAssertEqual(schedule.entries[2].hour, 8)
        XCTAssertEqual(schedule.entries[3].hour, 21)
    }

    func testIsDueRequiresEnabled() {
        let entry = SceneScheduleEntry(id: 0, hour: 19, minute: 0, sceneName: "阅读", enabled: false)
        let schedule = SceneSchedule(entries: [entry])
        XCTAssertFalse(schedule.isDue(entry, at: date(2026, 8, 9, 20, 0), appliedOn: nil, calendar: calendar))
    }

    func testIsDueBeforeTimeIsFalse() {
        let entry = SceneScheduleEntry(id: 0, hour: 19, minute: 0, sceneName: "阅读", enabled: true)
        let schedule = SceneSchedule(entries: [entry])
        XCTAssertFalse(schedule.isDue(entry, at: date(2026, 8, 9, 18, 0), appliedOn: nil, calendar: calendar))
    }

    func testIsDueAfterTimeIsTrue() {
        let entry = SceneScheduleEntry(id: 0, hour: 19, minute: 0, sceneName: "阅读", enabled: true)
        let schedule = SceneSchedule(entries: [entry])
        XCTAssertTrue(schedule.isDue(entry, at: date(2026, 8, 9, 19, 30), appliedOn: nil, calendar: calendar))
    }

    func testAppliedDaySuppressesSameDay() {
        let entry = SceneScheduleEntry(id: 0, hour: 19, minute: 0, sceneName: "阅读", enabled: true)
        let schedule = SceneSchedule(entries: [entry])
        let appliedOn = date(2026, 8, 9, 0, 0)
        XCTAssertFalse(schedule.isDue(entry, at: date(2026, 8, 9, 20, 0), appliedOn: appliedOn, calendar: calendar))
    }

    func testAppliedDayAllowsDifferentDay() {
        let entry = SceneScheduleEntry(id: 0, hour: 19, minute: 0, sceneName: "阅读", enabled: true)
        let schedule = SceneSchedule(entries: [entry])
        let appliedYesterday = date(2026, 8, 8, 0, 0)
        XCTAssertTrue(schedule.isDue(entry, at: date(2026, 8, 9, 20, 0), appliedOn: appliedYesterday, calendar: calendar))
    }

    /// Per-entry tracking: applying slot 0 on a day must not suppress slot 1
    /// even though both use the same "day" marker.
    func testPerEntryTracking() {
        let schedule = SceneSchedule.defaultSchedule()
        let reading = schedule.entries[0]
        let sleep = schedule.entries[1]
        var readingOn = reading
        var sleepOn = sleep
        readingOn.enabled = true
        sleepOn.enabled = true
        let due = SceneSchedule(entries: [readingOn, sleepOn])
        let appliedDay = date(2026, 8, 9, 0, 0)
        // Both entries were applied today, so neither is due again today...
        XCTAssertFalse(due.isDue(readingOn, at: date(2026, 8, 9, 20, 0), appliedOn: appliedDay, calendar: calendar))
        XCTAssertFalse(due.isDue(sleepOn, at: date(2026, 8, 9, 20, 0), appliedOn: appliedDay, calendar: calendar))
        // ...but a slot that was never applied today is still due after its time.
        XCTAssertTrue(due.isDue(sleepOn, at: date(2026, 8, 9, 23, 30), appliedOn: nil, calendar: calendar))
    }

    func testDueEntriesAreChronological() {
        var schedule = SceneSchedule.defaultSchedule()
        for index in schedule.entries.indices {
            schedule.entries[index].enabled = true
        }
        let due = schedule.dueEntries(
            at: date(2026, 8, 9, 23, 30),
            appliedDays: [:],
            calendar: calendar,
            policy: .replayAll)
        XCTAssertEqual(due.map(\.sceneName), ["专注", "阅读", "放松", "睡眠"])
    }

    func testDueEntriesLatestOnlyReturnsMostRecentElapsedSlot() {
        var schedule = SceneSchedule.defaultSchedule()
        for index in schedule.entries.indices {
            schedule.entries[index].enabled = true
        }
        let due = schedule.dueEntries(
            at: date(2026, 8, 9, 23, 30),
            appliedDays: [:],
            calendar: calendar)
        XCTAssertEqual(due.map(\.sceneName), ["睡眠"])
    }

    func testLatestOnlyPolicyHandlesMidnightRollover() {
        let entry = SceneScheduleEntry(
            id: 1, hour: 0, minute: 5, sceneName: "夜间", enabled: true)
        let schedule = SceneSchedule(entries: [entry])
        let yesterday = date(2026, 8, 8, 0, 0)
        let afterMidnight = date(2026, 8, 9, 0, 15)

        XCTAssertTrue(schedule.isDue(entry, at: afterMidnight, appliedOn: yesterday, calendar: calendar))
        XCTAssertEqual(
            schedule.dueEntries(at: afterMidnight, appliedDays: [:], calendar: calendar).map(\.id),
            [1])
    }
}
