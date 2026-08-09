import XCTest
@testable import YeelightLibraCore

@MainActor
final class LightControlUseCasesTests: XCTestCase {
    func testManualOperationPublishesFailureToSharedEntryPoint() async throws {
        let expected = NSError(domain: "test", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "offline"
        ])
        let client = YeelightClient(host: "192.168.1.10", commandHandler: { _, _ in
            throw expected
        })
        let automation = AutoModeController(client: client)
        defer { automation.stop() }
        let controls = LightControlUseCases(client: client, autoController: automation)

        controls.setMainBrightness(42)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controls.lastError, "主灯亮度失败：offline")
    }
}
