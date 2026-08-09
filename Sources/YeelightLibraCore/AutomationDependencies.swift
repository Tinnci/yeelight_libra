import Foundation
import Combine
import AppKit

protocol AutomationStore {
    func int(forKey key: String) -> Int?
    func bool(forKey key: String) -> Bool
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}

struct UserDefaultsAutomationStore: AutomationStore {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    func int(forKey key: String) -> Int? { defaults.object(forKey: key) as? Int }
    func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
}

protocol AutomationClock {
    var now: Date { get }
    var calendar: Calendar { get }
    func sleep(nanoseconds: UInt64) async throws
}

struct SystemAutomationClock: AutomationClock {
    var now: Date { Date() }
    var calendar: Calendar { Calendar.current }
    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

protocol ScreenSampling {
    func authorized() async -> Bool
    func sampleDisplay() async -> RGB?
}

extension ScreenColorSampler: ScreenSampling {}

protocol DisplayEventSource {
    var screensDidSleep: AnyPublisher<Notification, Never> { get }
    var screensDidWake: AnyPublisher<Notification, Never> { get }
}

struct WorkspaceDisplayEventSource: DisplayEventSource {
    let center: NotificationCenter
    init(_ center: NotificationCenter = NSWorkspace.shared.notificationCenter) { self.center = center }
    var screensDidSleep: AnyPublisher<Notification, Never> {
        center.publisher(for: NSWorkspace.screensDidSleepNotification).eraseToAnyPublisher()
    }
    var screensDidWake: AnyPublisher<Notification, Never> {
        center.publisher(for: NSWorkspace.screensDidWakeNotification).eraseToAnyPublisher()
    }
}
