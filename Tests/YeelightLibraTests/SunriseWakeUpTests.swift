import XCTest
@testable import YeelightLibraCore

final class SunriseWakeUpTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
    }

    private var wakeUp: SunriseWakeUp {
        SunriseWakeUp(alarmHour: 7, alarmMinute: 0, rampMinutes: 30)
    }

    func testWindowEndIsAlarmTime() {
        let day = date(2026, 8, 9, 0, 0)
        XCTAssertEqual(wakeUp.windowEnd(on: day, calendar: calendar), date(2026, 8, 9, 7, 0))
    }

    func testWindowStartIsAlarmMinusRamp() {
        let day = date(2026, 8, 9, 0, 0)
        XCTAssertEqual(wakeUp.windowStart(on: day, calendar: calendar), date(2026, 8, 9, 6, 30))
    }

    /// Alarm 00:15 with a 30-minute ramp starts at 23:45 the previous day.
    func testCrossMidnightWindowStart() {
        let night = SunriseWakeUp(alarmHour: 0, alarmMinute: 15, rampMinutes: 30)
        let day = date(2026, 8, 10, 0, 0)
        XCTAssertEqual(night.windowStart(on: day, calendar: calendar), date(2026, 8, 9, 23, 45))
    }

    func testProgressAtStartMidAndEnd() {
        let day = date(2026, 8, 9, 0, 0)
        XCTAssertEqual(wakeUp.progress(at: date(2026, 8, 9, 6, 30), on: day, calendar: calendar), 0)
        XCTAssertEqual(
            wakeUp.progress(at: date(2026, 8, 9, 6, 45), on: day, calendar: calendar) ?? -1,
            0.5,
            accuracy: 0.0001)
        XCTAssertNil(wakeUp.progress(at: date(2026, 8, 9, 7, 0), on: day, calendar: calendar))
        XCTAssertNil(wakeUp.progress(at: date(2026, 8, 9, 6, 0), on: day, calendar: calendar))
    }

    func testTargetInterpolation() {
        XCTAssertEqual(wakeUp.target(progress: 0).bright, 1)
        XCTAssertEqual(wakeUp.target(progress: 0).ct, 2700)
        XCTAssertEqual(wakeUp.target(progress: 1).bright, 100)
        XCTAssertEqual(wakeUp.target(progress: 1).ct, 5000)
        // (1 + 99*0.5).rounded() = 50.5 -> 51; 2700 + 2300*0.5 = 3850
        let mid = wakeUp.target(progress: 0.5)
        XCTAssertEqual(mid.bright, 51)
        XCTAssertEqual(mid.ct, 3850)
    }

    func testTargetClampsOutOfRangeProgress() {
        XCTAssertEqual(wakeUp.target(progress: -1).bright, 1)
        XCTAssertEqual(wakeUp.target(progress: 2).bright, 100)
    }

    func testNextOccurrenceAwaitingRampingTomorrow() {
        XCTAssertEqual(
            wakeUp.nextOccurrence(after: date(2026, 8, 9, 6, 0), calendar: calendar).phase, .awaiting)
        XCTAssertEqual(
            wakeUp.nextOccurrence(after: date(2026, 8, 9, 6, 45), calendar: calendar).phase, .ramping)
        let after = wakeUp.nextOccurrence(after: date(2026, 8, 9, 8, 0), calendar: calendar)
        XCTAssertEqual(after.phase, .awaiting)
        XCTAssertEqual(after.day, date(2026, 8, 10, 0, 0))
    }

    /// The pre-midnight half of a cross-midnight ramp must still be `.ramping`
    /// (anchored on the alarm day), not `.awaiting`.
    func testNextOccurrenceCrossMidnightRampsBeforeMidnight() {
        let night = SunriseWakeUp(alarmHour: 0, alarmMinute: 15, rampMinutes: 30)
        let beforeRamp = night.nextOccurrence(after: date(2026, 8, 9, 23, 30), calendar: calendar)
        XCTAssertEqual(beforeRamp.phase, .awaiting)
        XCTAssertEqual(beforeRamp.day, date(2026, 8, 10, 0, 0))

        let atRampStart = night.nextOccurrence(after: date(2026, 8, 9, 23, 45), calendar: calendar)
        XCTAssertEqual(atRampStart.phase, .ramping)
        XCTAssertEqual(atRampStart.day, date(2026, 8, 10, 0, 0))

        let midRamp = night.nextOccurrence(after: date(2026, 8, 10, 0, 5), calendar: calendar)
        XCTAssertEqual(midRamp.phase, .ramping)

        let afterRamp = night.nextOccurrence(after: date(2026, 8, 10, 0, 20), calendar: calendar)
        XCTAssertEqual(afterRamp.phase, .awaiting)
        XCTAssertEqual(afterRamp.day, date(2026, 8, 11, 0, 0))
    }
}
