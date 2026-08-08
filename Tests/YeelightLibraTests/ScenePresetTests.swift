import XCTest
@testable import YeelightLibraCore

final class ScenePresetTests: XCTestCase {
    // MARK: - Catalog invariants

    func testAllPresetsIsNonEmpty() {
        XCTAssertFalse(ScenePreset.all.isEmpty)
    }

    func testPresetNamesAreUnique() {
        let names = Set(ScenePreset.all.map(\.name))
        XCTAssertEqual(names.count, ScenePreset.all.count)
    }

    // MARK: - Per-preset value ranges

    /// Every preset must keep its values within the device protocol ranges:
    /// main brightness 1...100 and color temperature 1700...6500 when the main
    /// light is on; backlight brightness 1...100 and RGB 0...0xFFFFFF when the
    /// backlight is on. Off lights are allowed to hold zero placeholders.
    func testEnabledLightsKeepValuesWithinDeviceRanges() {
        for preset in ScenePreset.all {
            if preset.mainPower {
                XCTAssertTrue((1...100).contains(preset.mainBright),
                              "\(preset.name): mainBright \(preset.mainBright) out of 1...100")
                XCTAssertTrue((1700...6500).contains(preset.mainCT),
                              "\(preset.name): mainCT \(preset.mainCT) out of 1700...6500")
            }
            if preset.bgPower {
                XCTAssertTrue((1...100).contains(preset.bgBright),
                              "\(preset.name): bgBright \(preset.bgBright) out of 1...100")
                XCTAssertTrue((0...0xFFFFFF).contains(preset.bgRGB),
                              "\(preset.name): bgRGB \(preset.bgRGB) out of 0...0xFFFFFF")
            }
        }
    }

    // MARK: - Spot checks

    func testReadingPresetEnablesMainLightOnly() {
        XCTAssertTrue(ScenePreset.reading.mainPower)
        XCTAssertFalse(ScenePreset.reading.bgPower)
        XCTAssertEqual(ScenePreset.reading.mainBright, 80)
        XCTAssertEqual(ScenePreset.reading.mainCT, 4500)
    }

    func testSleepPresetEnablesBacklightOnly() {
        XCTAssertFalse(ScenePreset.sleep.mainPower)
        XCTAssertTrue(ScenePreset.sleep.bgPower)
        XCTAssertTrue((1...100).contains(ScenePreset.sleep.bgBright))
        XCTAssertEqual(ScenePreset.sleep.bgRGB, 0xFFDFB0)
    }

    func testFocusPresetHasBrightMainLight() {
        XCTAssertTrue(ScenePreset.focus.mainPower)
        XCTAssertEqual(ScenePreset.focus.mainBright, 100)
        XCTAssertEqual(ScenePreset.focus.mainCT, 6000)
        XCTAssertFalse(ScenePreset.focus.bgPower)
    }
}
