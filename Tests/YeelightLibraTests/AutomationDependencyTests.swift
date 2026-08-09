import XCTest
@testable import YeelightLibraCore

final class AutomationDependencyTests: XCTestCase {
    func testUserDefaultsStoreRoundTripsAutomationValues() {
        let suiteName = "YeelightLibraTests.automation-store"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsAutomationStore(defaults)

        store.set(42, forKey: "number")
        store.set(true, forKey: "flag")
        store.set(Data("value".utf8), forKey: "data")

        XCTAssertEqual(store.int(forKey: "number"), 42)
        XCTAssertTrue(store.bool(forKey: "flag"))
        XCTAssertEqual(store.data(forKey: "data"), Data("value".utf8))
    }

    func testSystemClockProvidesCalendarAndCurrentTime() {
        let before = Date()
        let clock = SystemAutomationClock()
        XCTAssertGreaterThanOrEqual(clock.now, before)
        XCTAssertEqual(clock.calendar.timeZone, Calendar.current.timeZone)
    }

    @MainActor
    func testAutomationControllerAcceptsInjectedStoreAndClock() {
        let suiteName = "YeelightLibraTests.automation-controller"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let client = YeelightClient(host: "192.168.1.10", commandHandler: { _, _ in [] })
        let controller = AutoModeController(
            client: client,
            store: UserDefaultsAutomationStore(defaults),
            clock: ThrowingAutomationClock())
        controller.stop()
        XCTAssertEqual(controller.wakeUpRampMinutes, 30)
    }
}

private struct ThrowingAutomationClock: AutomationClock {
    var now: Date { Date(timeIntervalSince1970: 1_000) }
    var calendar: Calendar { Calendar(identifier: .gregorian) }
    func sleep(nanoseconds: UInt64) async throws { throw CancellationError() }
}
