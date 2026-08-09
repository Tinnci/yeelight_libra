import XCTest
@testable import YeelightLibraCore

@MainActor
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
            XCTAssertTrue([1, 2, 7].contains(mode), "mode \(mode) not in {1,2,7}")
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
        snapshot.mainPower = true
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

    // MARK: - Automation arbitration

    func testCinemaExcludesAllOtherAutomaticModes() {
        var policy = AutomationArbitration()
        _ = policy.apply(.set(.circadian, enabled: true))
        _ = policy.apply(.set(.screenSync, enabled: true))
        _ = policy.apply(.set(.wakeUp, enabled: true))
        let disabled = policy.apply(.set(.cinema, enabled: true))

        XCTAssertEqual(policy.active, [.cinema])
        XCTAssertEqual(disabled, [.screenSync, .wakeUp])
    }

    func testManualControlOnlyReleasesModesForItsZone() {
        var policy = AutomationArbitration()
        _ = policy.apply(.set(.circadian, enabled: true))
        _ = policy.apply(.set(.screenSync, enabled: true))
        let disabled = policy.apply(.manualBacklightControl)

        XCTAssertEqual(policy.active, [.circadian])
        XCTAssertEqual(disabled, [.screenSync])
    }

    // MARK: - Workflow plans

    func testSceneWorkflowPreservesZoneOrdering() {
        let scene = ScenePreset(
            name: "测试", mainPower: true, mainBright: 40, mainCT: 3500,
            bgPower: true, bgBright: 20, bgRGB: 0x102030)
        XCTAssertEqual(
            LightWorkflowPlan.scene(scene).operations,
            [.setPower(true), .setBright(40), .setCT(3500),
             .setBGPower(true), .setBGRGB(0x102030), .setBGBright(20)])
    }

    func testRestoreWorkflowSkipsValuesForOffZones() {
        var state = LightState()
        state.mainPower = false
        state.bgPower = false
        XCTAssertEqual(
            LightWorkflowPlan.restore(state).operations,
            [.setPower(false), .setBGPower(false)])
    }

    func testDisplayWakeInvalidatesEarlierSleepGeneration() {
        var state = DisplayLinkState()
        let sleep = state.beginSleep()
        let wake = state.beginWake()

        XCTAssertFalse(state.owns(sleep))
        XCTAssertTrue(state.owns(wake))
        XCTAssertFalse(state.sleeping)
    }

    func testStoppingDisplayLinkInvalidatesPendingWork() {
        var state = DisplayLinkState()
        let generation = state.beginSleep()
        state.stop()

        XCTAssertFalse(state.owns(generation))
        XCTAssertFalse(state.sleeping)
    }

    func testWorkflowFailureReportsOperationAndCompletedCount() async {
        let plan = LightWorkflowPlan(operations: [
            .setPower(true), .setBright(40), .setCT(3500)
        ])
        let expected = NSError(domain: "test", code: 1)
        do {
            try await LightWorkflowRunner.run(plan) { operation in
                if operation == .setBright(40) { throw expected }
            }
            XCTFail("expected workflow failure")
        } catch let failure as LightWorkflowFailure {
            XCTAssertEqual(failure.operation, .setBright(40))
            XCTAssertEqual(failure.completedCount, 1)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testWorkflowReportsTheFirstFailedOperationAtEveryPosition() async {
        let operations: [LightWorkflowOperation] = [.setPower(true), .setBright(40), .setCT(3500)]
        for failureIndex in operations.indices {
            let plan = LightWorkflowPlan(operations: operations)
            do {
                try await LightWorkflowRunner.run(plan) { operation in
                    if operation == operations[failureIndex] {
                        throw NSError(domain: "test", code: failureIndex)
                    }
                }
                XCTFail("expected failure at index \(failureIndex)")
            } catch let failure as LightWorkflowFailure {
                XCTAssertEqual(failure.operation, operations[failureIndex])
                XCTAssertEqual(failure.completedCount, failureIndex)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }
}
