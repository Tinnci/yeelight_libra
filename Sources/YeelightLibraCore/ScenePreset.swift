import Foundation

/// A one-shot scene preset: a named combination of main-light and backlight
/// settings applied with a single tap.
struct ScenePreset: Equatable, Identifiable {
    let name: String
    let mainPower: Bool
    let mainBright: Int
    let mainCT: Int
    let bgPower: Bool
    let bgBright: Int
    let bgRGB: Int

    var id: String { name }

    static let reading = ScenePreset(
        name: "阅读",
        mainPower: true, mainBright: 80, mainCT: 4500,
        bgPower: false, bgBright: 0, bgRGB: 0)

    static let focus = ScenePreset(
        name: "专注",
        mainPower: true, mainBright: 100, mainCT: 6000,
        bgPower: false, bgBright: 0, bgRGB: 0)

    static let relax = ScenePreset(
        name: "放松",
        mainPower: false, mainBright: 0, mainCT: 2700,
        bgPower: true, bgBright: 40, bgRGB: 0xFFB84D)

    static let movie = ScenePreset(
        name: "电影",
        mainPower: false, mainBright: 0, mainCT: 2700,
        bgPower: true, bgBright: 25, bgRGB: 0x445588)

    static let sleep = ScenePreset(
        name: "睡眠",
        mainPower: false, mainBright: 0, mainCT: 2700,
        bgPower: true, bgBright: 15, bgRGB: 0xFFDFB0)

    static let all: [ScenePreset] = [.reading, .focus, .relax, .movie, .sleep]
}
