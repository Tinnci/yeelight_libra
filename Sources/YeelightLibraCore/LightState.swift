import Foundation

/// Local mirror of the device state, updated from `get_prop` results and
/// `props` notifications pushed by the lamp over the LAN API.
struct LightState: Equatable {
    /// Aggregate device power reported by the legacy `power` property.
    var power = false
    /// Front/main light power. On devices without `main_power`, this mirrors
    /// `power`; Light Bar Pro exposes the two properties separately.
    var mainPower = false
    var bright = 10
    var ct = 3200
    var colorMode = 2

    var bgPower = false
    var bgBright = 50
    var bgRGB = 13395711
    var bgCt = 4000

    var name = ""

    var mainStatusText: String { mainPower ? "开" : "关" }
    var bgStatusText: String { bgPower ? "开" : "关" }
}
