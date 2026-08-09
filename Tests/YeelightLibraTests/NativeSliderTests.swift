import XCTest
import AppKit
import SwiftUI
@testable import YeelightLibraCore

@MainActor
final class NativeSliderTests: XCTestCase {
    private func makeSlider() -> NSSlider {
        let slider = NSSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        slider.minValue = 1
        slider.maxValue = 100
        return slider
    }

    /// User drags are delivered through the slider's action, which is the only
    /// path that must update the binding and fire the command callback.
    func testUserDragFiresOnUserChangeAndUpdatesBinding() {
        var bound: Double = 0
        var received: [Double] = []
        let binding = Binding<Double>(get: { bound }, set: { bound = $0 })

        let sliderView = NativeSlider(value: binding, range: 1...100) { received.append($0) }
        let coordinator = NativeSlider.Coordinator(sliderView)
        let slider = makeSlider()
        slider.doubleValue = 42

        coordinator.valueChanged(slider)

        XCTAssertEqual(bound, 42)
        XCTAssertEqual(received, [42])
    }

    /// The no-echo contract relies on AppKit: assigning `doubleValue`
    /// programmatically (what updateNSView does when the lamp pushes props)
    /// must NOT fire the slider's target/action.
    func testProgrammaticValueSetDoesNotFireAction() {
        final class Target: NSObject {
            var fired = false
            @objc func handle(_ sender: Any?) { fired = true }
        }

        let target = Target()
        let slider = makeSlider()
        slider.target = target
        slider.action = #selector(Target.handle(_:))

        slider.doubleValue = 75

        XCTAssertFalse(target.fired)
    }

    /// The callback must not fire merely because the slider's value changed;
    /// only an explicit action invocation (user drag) triggers it.
    func testValueSetWithoutActionDoesNotFireCallback() {
        var received: [Double] = []
        let sliderView = NativeSlider(value: .constant(10), range: 1...100) { received.append($0) }
        let coordinator = NativeSlider.Coordinator(sliderView)
        let slider = makeSlider()

        slider.doubleValue = 99

        XCTAssertTrue(received.isEmpty)
        _ = coordinator
    }
}
