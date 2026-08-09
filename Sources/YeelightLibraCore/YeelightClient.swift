import Foundation
import Network
import Combine

/// Main-actor isolated TCP JSON client for Yeelight's LAN protocol.
///
/// The socket callbacks are bridged back to the main actor so connection
/// state, request IDs, response matching, and the published state mirror all
/// have one owner. This avoids the old split between an NWConnection queue and
/// arbitrary Tasks.
@MainActor
final class YeelightClient: ObservableObject {
    typealias CommandHandler = YeelightCommandHandler

    @Published var state = LightState()
    @Published var isConnected = false
    @Published private(set) var capabilities = DeviceCapabilities()

    static let defaultPort: NWEndpoint.Port = 55443
    static let defaultHost = "192.168.3.111"

    var host: String {
        didSet {
            guard oldValue != host else { return }
            UserDefaults.standard.set(host, forKey: "deviceIP")

            let wasRunning = chroma.isRunning
            chroma.stop()
            chroma = ChromaSession(host: host)
            if wasRunning { chroma.start() }

            // Never expose the previous device's state while the new address
            // is connecting.
            state = LightState()
            hasMainPowerProperty = false
            capabilities = DeviceCapabilities()
            isConnected = false
            replaceTransport()
        }
    }

    /// Alternative low-latency control channel (UDP 55444 token session).
    @Published var chroma: ChromaSession {
        didSet { bindChroma() }
    }
    @Published private(set) var chromaConnected = false

    private var transport: YeelightTCPTransport
    private var transportCancellable: AnyCancellable?
    private let commandHandler: CommandHandler?
    private var chromaCancellable: AnyCancellable?
    private var hasMainPowerProperty = false

    init(host: String, commandHandler: CommandHandler? = nil) {
        self.host = host
        self.chroma = ChromaSession(host: host)
        self.commandHandler = commandHandler
        self.transport = YeelightTCPTransport(host: host, commandHandler: commandHandler)
        bindChroma()
        bindTransport()
    }

    private func bindChroma() {
        chromaCancellable?.cancel()
        chromaCancellable = chroma.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.chromaConnected = connected
            }
    }

    private func bindTransport() {
        transportCancellable?.cancel()
        transportCancellable = transport.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in self?.isConnected = connected }
        transport.onProperties = { [weak self] params in self?.applyProps(params) }
        transport.onReady = { [weak self] in
            guard let self else { return }
            try await self.refresh()
            Logger.log(
                "state: power=\(self.state.power) mainPower=\(self.state.mainPower) "
                + "bright=\(self.state.bright) ct=\(self.state.ct) "
                + "bgPower=\(self.state.bgPower) bgRGB=\(self.state.bgRGB)")
        }
    }

    private func replaceTransport() {
        transport.disconnect()
        transportCancellable?.cancel()
        transport = YeelightTCPTransport(host: host, commandHandler: commandHandler)
        bindTransport()
        transport.start()
    }

    // MARK: - Connection

    func start() {
        transport.start()
    }

    func disconnect() {
        transport.disconnect()
    }

    func command(_ request: YeelightRequest) async throws -> [Any] {
        try await transport.send(request)
    }

    // MARK: - Convenience API

    func setPower(_ on: Bool) async throws {
        let previousBacklight = state.bgPower
        _ = try await command(.setPower(on))
        projectMainPower(on)

        // Some dual-zone devices couple `set_power` to the background light.
        // Reassert the previous background state so this API remains a main
        // light operation instead of falling back to dev_toggle (which toggles
        // both zones).
        if hasMainPowerProperty || previousBacklight {
            try await setBGPower(previousBacklight)
        }
    }

    func setBright(_ value: Int) async throws {
        _ = try await command(.setBright(value))
    }

    func setCT(_ value: Int) async throws {
        _ = try await command(.setCT(value))
    }

    func setBGPower(_ on: Bool) async throws {
        _ = try await command(.setBGPower(on))
        projectBacklightPower(on)
        if !on {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let result = try? await command(.getProp(["bg_power"])),
               (result.first as? String) == "on" {
                _ = try await command(.setBGPower(false, transition: "sudden", duration: 0))
            }
        }
    }

    func setBGBright(_ value: Int) async throws {
        _ = try await command(.setBGBright(value))
    }

    func setBGRGB(_ rgb: Int) async throws {
        _ = try await command(.setBGRGB(rgb))
    }

    func setBGCT(_ value: Int) async throws {
        _ = try await command(.setBGCT(value))
    }

    /// Apply a one-shot scene preset: main-light and backlight settings in one tap.
    func applyScene(_ scene: ScenePreset) async throws {
        try await apply(LightWorkflowPlan.scene(scene))
    }

    /// Execute a typed workflow in order. A failure identifies the operation
    /// and number of operations already completed so callers can reconcile or
    /// retry deliberately instead of treating a partial workflow as atomic.
    func apply(_ plan: LightWorkflowPlan) async throws {
        try await LightWorkflowRunner.run(plan) { [self] operation in
            switch operation {
            case .setPower(let value): try await setPower(value)
            case .setBright(let value): try await setBright(value)
            case .setCT(let value): try await setCT(value)
            case .setBGPower(let value): try await setBGPower(value)
            case .setBGBright(let value): try await setBGBright(value)
            case .setBGRGB(let value): try await setBGRGB(value)
            case .startBGFlow(let expression): try await startBGColorFlow(expression)
            case .stopBGFlow: try await stopBGColorFlow()
            }
        }
    }

    // MARK: - Timer (cron)

    static func cronOffParameters(afterMinutes minutes: Int) -> [Int] {
        [0, max(1, minutes)]
    }

    /// The protocol takes the delay directly in minutes.
    func setCronOff(afterMinutes minutes: Int) async throws {
        _ = try await command(.cronAdd(minutes))
    }

    /// Reflect a successful fire-and-forget Chroma power command immediately.
    /// The next TCP `props`/`get_prop` update remains authoritative.
    func projectBacklightPower(_ on: Bool) {
        var updated = state
        updated.bgPower = on
        state = updated
    }

    private func projectMainPower(_ on: Bool) {
        var updated = state
        updated.mainPower = on
        if !hasMainPowerProperty {
            updated.power = on
        }
        state = updated
    }

    /// Remaining delay in minutes of the scheduled power-off, or nil.
    func getCronOffDelayMinutes() async throws -> Int? {
        let result = try await command(.cronGet)
        guard let entry = result.first as? [String: Any],
              let delay = Self.intOrNil(entry["delay"]) else { return nil }
        return delay
    }

    func cancelCronOff() async throws {
        _ = try await command(.cronDelete)
    }

    // MARK: - Color flow

    func startBGColorFlow(_ expression: String) async throws {
        _ = try await command(.startBGFlow(expression))
    }

    func stopBGColorFlow() async throws {
        _ = try await command(.stopBGFlow)
    }

    func startMainColorFlow(_ expression: String) async throws {
        _ = try await command(.startMainFlow(expression))
    }

    func stopMainColorFlow() async throws {
        _ = try await command(.stopMainFlow)
    }

    // MARK: - Segments

    /// Device-specific extension; callers should only expose it when the
    /// device advertises `set_segment_rgb` in its support list.
    func setSegmentRGB(start: Int, end: Int, rgb: Int) async throws {
        guard supports("set_segment_rgb") else {
            throw unsupportedMethod("set_segment_rgb")
        }
        _ = try await command(.setSegment(start: start, end: end, rgb: rgb))
    }

    func supports(_ method: String) -> Bool {
        capabilities.supports(method)
    }

    // MARK: - State

    @MainActor
    func refresh() async throws {
        let coreProps = ["power", "bright", "ct", "color_mode", "name"]
        let coreResult = try await command(.getProp(coreProps))
        guard coreResult.count >= coreProps.count else { return }

        var params: [String: Any] = [:]
        for (index, property) in coreProps.enumerated() {
            params[property] = coreResult[index]
        }
        state = YeelightStateMapper.applyProps(
            params,
            to: state,
            hasMainPower: &hasMainPowerProperty)

        let backgroundProps = ["bg_power", "bg_bright", "bg_rgb", "bg_ct"]
        if let backgroundResult = try? await command(.getProp(backgroundProps)),
           backgroundResult.count >= backgroundProps.count {
            var backgroundParams: [String: Any] = [:]
            for (index, property) in backgroundProps.enumerated() {
                backgroundParams[property] = backgroundResult[index]
            }
            state = YeelightStateMapper.applyProps(
                backgroundParams,
                to: state,
                hasMainPower: &hasMainPowerProperty)
        }

        if let mainPowerResult = try? await command(.getProp(["main_power"])),
           let mainPower = mainPowerResult.first {
            state = YeelightStateMapper.applyProps(
                ["main_power": mainPower],
                to: state,
                hasMainPower: &hasMainPowerProperty)
        }
        if let supportResult = try? await command(.getProp(["support"])),
           let support = supportResult.first {
            capabilities.update(from: support)
        }
    }

    private func applyProps(_ params: [String: Any]) {
        state = YeelightStateMapper.applyProps(
            params,
            to: state,
            hasMainPower: &hasMainPowerProperty)
    }

    private static func intOrNil(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func unsupportedMethod(_ method: String) -> NSError {
        NSError(
            domain: "yeelight",
            code: -7,
            userInfo: [NSLocalizedDescriptionKey: "设备不支持 \(method)"])
    }
}
