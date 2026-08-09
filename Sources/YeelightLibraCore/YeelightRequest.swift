import Foundation

/// Typed request vocabulary for device operations. The raw method name and
/// heterogeneous wire parameters are derived only inside this protocol seam.
enum YeelightRequest: Equatable {
    case setPower(Bool)
    case setBright(Int)
    case setCT(Int)
    case setBGPower(Bool, transition: String = "smooth", duration: Int = 500)
    case setBGBright(Int)
    case setBGRGB(Int)
    case setBGCT(Int)
    case getProp([String])
    case cronAdd(Int)
    case cronGet
    case cronDelete
    case startBGFlow(String)
    case stopBGFlow
    case startMainFlow(String)
    case stopMainFlow
    case setSegment(start: Int, end: Int, rgb: Int)

    var method: String {
        switch self {
        case .setPower: return "set_power"
        case .setBright: return "set_bright"
        case .setCT: return "set_ct_abx"
        case .setBGPower: return "bg_set_power"
        case .setBGBright: return "bg_set_bright"
        case .setBGRGB: return "bg_set_rgb"
        case .setBGCT: return "bg_set_ct_abx"
        case .getProp: return "get_prop"
        case .cronAdd: return "cron_add"
        case .cronGet: return "cron_get"
        case .cronDelete: return "cron_del"
        case .startBGFlow: return "bg_start_cf"
        case .stopBGFlow: return "bg_stop_cf"
        case .startMainFlow: return "start_cf"
        case .stopMainFlow: return "stop_cf"
        case .setSegment: return "set_segment_rgb"
        }
    }

    var params: [Any] {
        switch self {
        case .setPower(let on): return [on ? "on" : "off", "smooth", 500]
        case .setBright(let value): return [value, "smooth", 200]
        case .setCT(let value): return [value, "smooth", 200]
        case .setBGPower(let on, let transition, let duration):
            return [on ? "on" : "off", transition, duration]
        case .setBGBright(let value): return [value, "smooth", 200]
        case .setBGRGB(let value): return [value, "smooth", 200]
        case .setBGCT(let value): return [value, "smooth", 200]
        case .getProp(let properties): return properties
        case .cronAdd(let minutes): return [0, max(1, minutes)]
        case .cronGet, .cronDelete: return [0]
        case .startBGFlow(let expression): return [0, 0, expression]
        case .stopBGFlow, .stopMainFlow: return []
        case .startMainFlow(let expression): return [0, 0, expression]
        case .setSegment(let start, let end, let rgb):
            return [start, end, rgb, "smooth", 300]
        }
    }
}
