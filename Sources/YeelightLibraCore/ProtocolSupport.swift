import Foundation

/// Shared wire-format helpers for the TCP and Chroma UDP variants of the
/// Yeelight JSON protocol. Both transports use JSON followed by CRLF.
enum YeelightProtocol {
    static func commandLine(
        id: Int,
        method: String,
        params: [Any],
        token: String? = nil
    ) throws -> Data {
        var object: [String: Any] = [
            "id": id,
            "method": method,
            "params": params,
        ]
        if let token {
            object["token"] = token
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw NSError(
                domain: "yeelight",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "命令编码失败"])
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(contentsOf: Data("\r\n".utf8))
        return data
    }
}

/// Methods advertised by the device's standard support property.
/// An empty set means discovery has not completed yet, so callers may
/// optimistically try a method and handle the protocol error.
struct DeviceCapabilities: Equatable {
    private(set) var methods: Set<String> = []
    private(set) var discovered = false

    mutating func update(from support: Any?) {
        guard let support = support as? String else { return }
        methods = Set(
            support
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        discovered = true
    }

    func supports(_ method: String) -> Bool {
        !discovered || methods.contains(method)
    }
}

/// Valid color-flow expressions used by the UI and cinema mode.
/// Flow mode 3 is the device's HSV state mode, not a supported color-flow
/// tuple mode. HSV hues are therefore converted to RGB tuples here.
enum FlowExpression {
    static let breath = "1200, 1, 16711680, 60; 1200, 1, 16711680, 5"

    static let rainbow = "500, 1, 16711680, 100; "
        + "500, 1, 16776960, 100; "
        + "500, 1, 65280, 100; "
        + "500, 1, 65535, 100; "
        + "500, 1, 255, 100; "
        + "500, 1, 16711935, 100"

    static let aurora = "800, 1, 65280, 40; 800, 1, 65535, 60; "
        + "800, 1, 16711935, 50; 800, 1, 16711680, 40"

    static let cinema = [0x445588, 0x663366, 0x225566, 0x884455]
        .map { "5000, 1, \($0), 30" }
        .joined(separator: "; ")
}

/// Pure state mapping kept separate from the socket layer so device-specific
/// `main_power` behavior can be regression-tested without a real lamp.
enum YeelightStateMapper {
    static func applyProps(
        _ params: [String: Any],
        to state: LightState,
        hasMainPower: inout Bool
    ) -> LightState {
        var updated = state

        if let value = power(params["power"]) {
            updated.power = value
            if !hasMainPower {
                updated.mainPower = value
            }
        }
        if let value = power(params["main_power"]) {
            hasMainPower = true
            updated.mainPower = value
        }
        if let value = int(params["bright"]) { updated.bright = value }
        if let value = int(params["ct"]) { updated.ct = value }
        if let value = int(params["color_mode"]) { updated.colorMode = value }
        if let value = power(params["bg_power"]) { updated.bgPower = value }
        if let value = int(params["bg_bright"]) { updated.bgBright = value }
        if let value = int(params["bg_rgb"]) { updated.bgRGB = value }
        if let value = int(params["bg_ct"]) { updated.bgCt = value }
        if let value = string(params["name"]) { updated.name = value }

        return updated
    }

    private static func power(_ value: Any?) -> Bool? {
        guard let text = string(value), !text.isEmpty else { return nil }
        return text == "on"
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
