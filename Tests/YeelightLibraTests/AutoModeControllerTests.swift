import XCTest
@testable import YeelightLibraCore

final class AutoModeControllerTests: XCTestCase {
    // MARK: - Cinema flow expression

    /// The cinema expression must be a valid `bg_start_cf` payload: steps of
    /// "duration_ms, mode, value, brightness" with mode 1 (RGB), in-range
    /// color values and brightness, and a slow duration.
    func testCinemaFlowExpressionIsValidFlowPayload() {
        let steps = AutoModeController.cinemaFlowExpression
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertGreaterThanOrEqual(steps.count, 2)
        for step in steps {
            let parts = step.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(parts.count, 4, "step: \(step)")
            let duration = Int(parts[0]) ?? 0
            let mode = Int(parts[1]) ?? 0
            let value = Int(parts[2]) ?? -1
            let bright = Int(parts[3]) ?? 0
            XCTAssertGreaterThanOrEqual(duration, 1000, "cinema steps should be slow")
            XCTAssertTrue([1, 2, 3].contains(mode), "mode \(mode) not in {1,2,3}")
            XCTAssertTrue((0...0xFFFFFF).contains(value), "value \(value) out of RGB range")
            XCTAssertTrue((1...100).contains(bright), "brightness \(bright) out of range")
        }
    }

    // MARK: - Restore plan

    func testRestorePlanMapsOffChannelsToNil() {
        var snapshot = LightState()
        snapshot.power = false
        snapshot.bright = 80
        snapshot.ct = 5000
        snapshot.bgPower = false
        snapshot.bgBright = 60
        snapshot.bgRGB = 12345
        let plan = AutoModeController.restorePlan(for: snapshot)
        XCTAssertEqual(plan.mainPower, false)
        XCTAssertNil(plan.mainBright)
        XCTAssertNil(plan.mainCT)
        XCTAssertEqual(plan.bgPower, false)
        XCTAssertNil(plan.bgBright)
        XCTAssertNil(plan.bgRGB)
    }

    func testRestorePlanKeepsValuesWhenOn() {
        var snapshot = LightState()
        snapshot.power = true
        snapshot.bright = 77
        snapshot.ct = 4200
        snapshot.bgPower = true
        snapshot.bgBright = 33
        snapshot.bgRGB = 0x112233
        let plan = AutoModeController.restorePlan(for: snapshot)
        XCTAssertEqual(plan.mainPower, true)
        XCTAssertEqual(plan.mainBright, 77)
        XCTAssertEqual(plan.mainCT, 4200)
        XCTAssertEqual(plan.bgPower, true)
        XCTAssertEqual(plan.bgBright, 33)
        XCTAssertEqual(plan.bgRGB, 0x112233)
    }

    // MARK: - Circadian hysteresis

    func testShouldApplyOnlyOnMeaningfulDrift() {
        XCTAssertFalse(AutoModeController.shouldApply(
            targetBright: 50, targetCT: 4000,
            currentBright: 50, currentCT: 4000))
        XCTAssertFalse(AutoModeController.shouldApply(
            targetBright: 51, targetCT: 4000,
            currentBright: 50, currentCT: 4010))
        XCTAssertTrue(AutoModeController.shouldApply(
            targetBright: 53, targetCT: 4000,
            currentBright: 50, currentCT: 4000))
        XCTAssertTrue(AutoModeController.shouldApply(
            targetBright: 50, targetCT: 4050,
            currentBright: 50, currentCT: 4000))
    }
}
