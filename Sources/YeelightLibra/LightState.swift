import Foundation

/// Local mirror of the device state, updated from `get_prop` results and
/// `props` notifications pushed by the lamp over the LAN API.
struct LightState: Equatable {
    var power = false
    var bright = 10
    var ct = 3200
    var colorMode = 2

    var bgPower = false
    var bgBright = 50
    var bgRGB = 13395711
    var bgCt = 4000

    var name = ""

    var mainStatusText: String { power ? "开" : "关" }
    var bgStatusText: String { bgPower ? "开" : "关" }
}
