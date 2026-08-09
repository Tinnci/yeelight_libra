import XCTest
@testable import YeelightLibraCore

@MainActor
final class ProtocolPayloadTests: XCTestCase {
    private func object(from data: Data) throws -> [String: Any] {
        let line = data.dropLast(2)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
    }

    func testTCPCommandIsCRLFTerminatedAndKeepsParams() throws {
        let data = try YeelightProtocol.commandLine(
            id: 7, method: "cron_add", params: [0, 60])
        XCTAssertEqual(data.suffix(2), Data("\r\n".utf8))
        let object = try object(from: data)
        XCTAssertEqual(object["id"] as? Int, 7)
        XCTAssertEqual(object["method"] as? String, "cron_add")
        XCTAssertEqual(object["params"] as? [Int], [0, 60])
    }

    func testCronUsesMinutesAndExactlyTwoParameters() {
        XCTAssertEqual(YeelightClient.cronOffParameters(afterMinutes: 30), [0, 30])
        XCTAssertEqual(YeelightClient.cronOffParameters(afterMinutes: 120), [0, 120])
    }

    func testChromaBacklightPowerUsesFullPowerPayload() {
        let on = ChromaSession.backlightPowerParameters(on: true)
        XCTAssertEqual(on.count, 3)
        XCTAssertEqual(on[0] as? String, "on")
        XCTAssertEqual(on[1] as? String, "smooth")
        XCTAssertEqual(on[2] as? Int, 500)

        let off = ChromaSession.backlightPowerParameters(on: false)
        XCTAssertEqual(off.count, 3)
        XCTAssertEqual(off[0] as? String, "off")
        XCTAssertEqual(off[1] as? String, "smooth")
        XCTAssertEqual(off[2] as? Int, 500)
    }

    func testRainbowFlowUsesOnlySupportedFlowModes() {
        for step in FlowExpression.rainbow.split(separator: ";") {
            let fields = step.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(fields.count, 4)
            XCTAssertEqual(Int(fields[1]), 1)
        }
    }

    func testChromaCommandIncludesToken() throws {
        let data = try YeelightProtocol.commandLine(
            id: 9, method: "bg_set_rgb", params: [0x112233, "sudden", 0], token: "token")
        let object = try object(from: data)
        XCTAssertEqual(object["token"] as? String, "token")
    }

    func testDeviceCapabilitiesParseSupportListAndOptimisticallyAllowUnknown() {
        var capabilities = DeviceCapabilities()
        XCTAssertTrue(capabilities.supports("set_segment_rgb"))

        capabilities.update(from: "set_rgb, set_ct_abx, bg_set_rgb")
        XCTAssertTrue(capabilities.supports("bg_set_rgb"))
        XCTAssertFalse(capabilities.supports("set_segment_rgb"))
    }
}

@MainActor
final class LightStateMappingTests: XCTestCase {
    func testMainPowerIsPreferredWhenDeviceReportsIt() {
        var state = LightState()
        var hasMainPower = false
        state = YeelightStateMapper.applyProps(
            ["power": "on", "main_power": "off", "bg_power": "on"],
            to: state,
            hasMainPower: &hasMainPower)

        XCTAssertTrue(hasMainPower)
        XCTAssertTrue(state.power)
        XCTAssertFalse(state.mainPower)
        XCTAssertTrue(state.bgPower)
    }

    func testGenericPowerMirrorsToMainPowerWhenMainPowerIsAbsent() {
        var state = LightState()
        var hasMainPower = false
        state = YeelightStateMapper.applyProps(
            ["power": "on"], to: state, hasMainPower: &hasMainPower)

        XCTAssertFalse(hasMainPower)
        XCTAssertTrue(state.power)
        XCTAssertTrue(state.mainPower)
    }
}

@MainActor
final class YeelightClientStateProjectionTests: XCTestCase {
    func testSuccessfulSetPowerUpdatesMainPowerWithoutPropsNotification() async throws {
        let client = YeelightClient(
            host: "192.168.1.10",
            commandHandler: { _, _ in [] })
        client.state.mainPower = true
        client.state.power = true

        try await client.setPower(false)

        XCTAssertFalse(client.state.mainPower)
        XCTAssertFalse(client.state.power)
    }

    func testSleepSceneProjectsMainAndBacklightPowerWithoutPropsNotification() async throws {
        let client = YeelightClient(
            host: "192.168.1.10",
            commandHandler: { _, _ in [] })
        client.state.mainPower = true
        client.state.power = true
        client.state.bgPower = false

        try await client.applyScene(.sleep)

        XCTAssertFalse(client.state.mainPower)
        XCTAssertFalse(client.state.power)
        XCTAssertTrue(client.state.bgPower)
    }
}
