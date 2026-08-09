import XCTest
@testable import YeelightLibraCore

final class CircadianScheduleTests: XCTestCase {
    private let schedule = CircadianSchedule.default

    func testDefaultScheduleHasAnchors() {
        XCTAssertFalse(schedule.anchors.isEmpty)
    }

    /// Every minute of the day must map to device-valid main-light values.
    func testTargetsStayWithinDeviceRangesAcrossTheDay() {
        for minute in stride(from: 0, to: 1440, by: 15) {
            let target = schedule.target(minutesSinceMidnight: minute)
            XCTAssertTrue(CircadianSchedule.brightRange.contains(target.bright),
                          "minute \(minute): bright \(target.bright)")
            XCTAssertTrue(CircadianSchedule.ctRange.contains(target.ct),
                          "minute \(minute): ct \(target.ct)")
        }
    }

    func testExactAnchorMatches() {
        let noon = schedule.target(minutesSinceMidnight: 12 * 60)
        XCTAssertEqual(noon.bright, 100)
        XCTAssertEqual(noon.ct, 6500)
    }

    /// 10:30 is halfway between the 09:00 (85, 5500) and 12:00 (100, 6500) anchors.
    func testMidpointInterpolation() {
        let mid = schedule.target(minutesSinceMidnight: 10 * 60 + 30)
        XCTAssertEqual(mid.bright, 93)   // (85 + 15 * 0.5).rounded()
        XCTAssertEqual(mid.ct, 6000)     // 5500 + 1000 * 0.5
    }

    /// 02:00 falls in the wrap interval between 23:00 (25, 2700) and
    /// 06:00 (45, 2700); the CT stays constant, brightness climbs partway.
    func testMidnightWrapInterpolatesFromNightToSunrise() {
        let night = schedule.target(minutesSinceMidnight: 2 * 60)
        XCTAssertEqual(night.ct, 2700)
        XCTAssertGreaterThan(night.bright, 25)
        XCTAssertLessThan(night.bright, 45)
    }

    func testClampingWhenAnchorOutsideRange() {
        let aggressive = CircadianSchedule(anchors: [
            CircadianSchedule.Anchor(minutes: 0, bright: 500, ct: 100),
            CircadianSchedule.Anchor(minutes: 12 * 60, bright: -5, ct: 9999),
        ])
        let target = aggressive.target(minutesSinceMidnight: 0)
        XCTAssertEqual(target.bright, CircadianSchedule.brightRange.upperBound)
        XCTAssertEqual(target.ct, CircadianSchedule.ctRange.lowerBound)
    }

    func testSingleAnchorReturnsAnchorValue() {
        let single = CircadianSchedule(anchors: [
            CircadianSchedule.Anchor(minutes: 8 * 60, bright: 60, ct: 4000),
        ])
        for minute in [0, 5 * 60, 8 * 60, 20 * 60] {
            let target = single.target(minutesSinceMidnight: minute)
            XCTAssertEqual(target.bright, 60)
            XCTAssertEqual(target.ct, 4000)
        }
    }
}
