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
            connectNow()
        }
    }

    /// Alternative low-latency control channel (UDP 55444 token session).
    @Published var chroma: ChromaSession {
        didSet { bindChroma() }
    }
    @Published private(set) var chromaConnected = false

    private var connection: NWConnection?
    private var buffer = Data()
    private var nextID = 1

    /// JSONSerialization represents protocol arrays as [Any], which is not
    /// statically Sendable even though this entire value stays on the main
    /// actor. Keep the actor boundary explicit at the continuation.
    private struct CommandResult: @unchecked Sendable {
        let values: [Any]
    }

    private struct PendingCommand {
        let handler: (Result<CommandResult, Error>) -> Void
        let timeout: DispatchWorkItem
    }

    private var pending: [Int: PendingCommand] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var generation = 0
    private var chromaCancellable: AnyCancellable?
    private var hasMainPowerProperty = false

    init(host: String) {
        self.host = host
        self.chroma = ChromaSession(host: host)
        bindChroma()
    }

    private func bindChroma() {
        chromaCancellable?.cancel()
        chromaCancellable = chroma.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.chromaConnected = connected
            }
    }

    // MARK: - Connection

    func start() {
        connectNow()
    }

    func disconnect() {
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: false)
        failAllPending(with: "连接已断开")
        isConnected = false
    }

    private func connectNow() {
        reconnectTask?.cancel()
        reconnectTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        generation += 1
        let gen = generation

        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: false)
        failAllPending(with: "连接已重置")
        isConnected = false

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: Self.defaultPort,
            using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleConnectionState(state, gen: gen)
            }
        }
        conn.start(queue: .main)
    }

    private func handleConnectionState(_ state: NWConnection.State, gen: Int) {
        guard gen == generation else { return }
        switch state {
        case .ready:
            onReady(gen: gen)
        case .waiting(let error):
            Logger.log("conn gen \(gen): waiting (\(error))")
            scheduleWaitingWatchdog(gen: gen)
        case .failed(let error):
            Logger.log("conn gen \(gen): failed (\(error))")
            onFailure(gen: gen)
        case .cancelled:
            if connection != nil { onFailure(gen: gen) }
        default:
            break
        }
    }

    private func onReady(gen: Int) {
        guard gen == generation else { return }
        watchdogTask?.cancel()
        isConnected = true
        Logger.log("connected to \(host)")
        receiveLoop(gen: gen)
        Task { @MainActor [weak self] in
            guard let self, gen == self.generation else { return }
            do {
                try await self.refresh()
                Logger.log(
                    "state: power=\(self.state.power) mainPower=\(self.state.mainPower) "
                    + "bright=\(self.state.bright) ct=\(self.state.ct) "
                    + "bgPower=\(self.state.bgPower) bgRGB=\(self.state.bgRGB)")
            } catch {
                Logger.log("refresh failed: \(error)")
            }
        }
    }

    private func onFailure(gen: Int) {
        guard gen == generation else { return }
        generation += 1
        let reconnectGeneration = generation
        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: false)
        isConnected = false
        failAllPending(with: "连接已断开")
        scheduleReconnect(gen: reconnectGeneration)
    }

    private func scheduleReconnect(gen: Int) {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, gen == self.generation else { return }
            self.connectNow()
        }
    }

    private func scheduleWaitingWatchdog(gen: Int) {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, gen == self.generation else { return }
            guard self.connection?.state != .ready else { return }
            Logger.log("conn gen \(gen): stuck, reconnecting")
            self.connectNow()
        }
    }

    private func receiveLoop(gen: Int) {
        guard gen == generation else { return }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.processBuffer()
                }
                if isComplete || error != nil {
                    self.onFailure(gen: gen)
                    return
                }
                self.receiveLoop(gen: gen)
            }
        }
    }

    private func processBuffer() {
        let separator = Data("\r\n".utf8)
        while let range = buffer.range(of: separator) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                handleLine(text)
            }
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let method = object["method"] as? String, method == "props",
           let params = object["params"] as? [String: Any] {
            applyProps(params)
            return
        }

        guard let id = Self.intOrNil(object["id"]),
              let command = pending.removeValue(forKey: id) else { return }
        command.timeout.cancel()

        if let result = object["result"] as? [Any] {
            command.handler(.success(CommandResult(values: result)))
        } else if let error = object["error"] as? [String: Any],
                  let message = error["message"] as? String {
            command.handler(.failure(NSError(
                domain: "yeelight",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])))
        } else {
            command.handler(.failure(NSError(
                domain: "yeelight",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "无法解析响应"])))
        }
    }

    private func failAllPending(with message: String) {
        let commands = pending
        pending.removeAll()
        let error = NSError(
            domain: "yeelight",
            code: -3,
            userInfo: [NSLocalizedDescriptionKey: message])
        for command in commands.values {
            command.timeout.cancel()
            command.handler(.failure(error))
        }
    }

    // MARK: - Commands

    @discardableResult
    func command(_ method: String, _ params: [Any]) async throws -> [Any] {
        let id = nextID
        nextID += 1
        let data = try YeelightProtocol.commandLine(id: id, method: method, params: params)

        let result: CommandResult = try await withCheckedThrowingContinuation { continuation in
            guard let conn = connection, conn.state == .ready else {
                continuation.resume(throwing: NSError(
                    domain: "yeelight",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "未连接设备"]))
                return
            }

            let timeout = DispatchWorkItem { [weak self] in
                guard let self, let command = self.pending.removeValue(forKey: id) else { return }
                command.handler(.failure(NSError(
                    domain: "yeelight",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "命令超时"])))
            }
            pending[id] = PendingCommand(
                handler: { result in continuation.resume(with: result) },
                timeout: timeout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)

            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard let self,
                          let command = self.pending.removeValue(forKey: id) else { return }
                    command.timeout.cancel()
                    command.handler(.failure(error))
                }
            })
        }
        return result.values
    }

    // MARK: - Convenience API

    func setPower(_ on: Bool) async throws {
        let previousBacklight = state.bgPower
        _ = try await command("set_power", [on ? "on" : "off", "smooth", 500])

        // Some dual-zone devices couple `set_power` to the background light.
        // Reassert the previous background state so this API remains a main
        // light operation instead of falling back to dev_toggle (which toggles
        // both zones).
        if hasMainPowerProperty || previousBacklight {
            try await setBGPower(previousBacklight)
        }
    }

    func setBright(_ value: Int) async throws {
        _ = try await command("set_bright", [value, "smooth", 200])
    }

    func setCT(_ value: Int) async throws {
        _ = try await command("set_ct_abx", [value, "smooth", 200])
    }

    func setBGPower(_ on: Bool) async throws {
        _ = try await command("bg_set_power", [on ? "on" : "off", "smooth", 500])
        if !on {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let result = try? await command("get_prop", ["bg_power"]),
               (result.first as? String) == "on" {
                _ = try await command("bg_set_power", ["off", "sudden", 0])
            }
        }
    }

    func setBGBright(_ value: Int) async throws {
        _ = try await command("bg_set_bright", [value, "smooth", 200])
    }

    func setBGRGB(_ rgb: Int) async throws {
        _ = try await command("bg_set_rgb", [rgb, "smooth", 200])
    }

    func setBGCT(_ value: Int) async throws {
        _ = try await command("bg_set_ct_abx", [value, "smooth", 200])
    }

    /// Apply a one-shot scene preset: main-light and backlight settings in one tap.
    func applyScene(_ scene: ScenePreset) async throws {
        if scene.mainPower {
            try await setPower(true)
            try await setBright(scene.mainBright)
            try await setCT(scene.mainCT)
        } else {
            try await setPower(false)
        }
        if scene.bgPower {
            try await setBGPower(true)
            try await setBGRGB(scene.bgRGB)
            try await setBGBright(scene.bgBright)
        } else {
            try await setBGPower(false)
        }
    }

    // MARK: - Timer (cron)

    static func cronOffParameters(afterMinutes minutes: Int) -> [Int] {
        [0, max(1, minutes)]
    }

    /// The protocol takes the delay directly in minutes.
    func setCronOff(afterMinutes minutes: Int) async throws {
        _ = try await command("cron_add", Self.cronOffParameters(afterMinutes: minutes))
    }

    /// Remaining delay in minutes of the scheduled power-off, or nil.
    func getCronOffDelayMinutes() async throws -> Int? {
        let result = try await command("cron_get", [0])
        guard let entry = result.first as? [String: Any],
              let delay = Self.intOrNil(entry["delay"]) else { return nil }
        return delay
    }

    func cancelCronOff() async throws {
        _ = try await command("cron_del", [0])
    }

    // MARK: - Color flow

    func startBGColorFlow(_ expression: String) async throws {
        _ = try await command("bg_start_cf", [0, 0, expression])
    }

    func stopBGColorFlow() async throws {
        _ = try await command("bg_stop_cf", [])
    }

    func startMainColorFlow(_ expression: String) async throws {
        _ = try await command("start_cf", [0, 0, expression])
    }

    func stopMainColorFlow() async throws {
        _ = try await command("stop_cf", [])
    }

    // MARK: - Segments

    /// Device-specific extension; callers should only expose it when the
    /// device advertises `set_segment_rgb` in its support list.
    func setSegmentRGB(start: Int, end: Int, rgb: Int) async throws {
        guard supports("set_segment_rgb") else {
            throw unsupportedMethod("set_segment_rgb")
        }
        _ = try await command("set_segment_rgb", [start, end, rgb, "smooth", 300])
    }

    func supports(_ method: String) -> Bool {
        capabilities.supports(method)
    }

    // MARK: - State

    @MainActor
    func refresh() async throws {
        let coreProps = ["power", "bright", "ct", "color_mode", "name"]
        let coreResult = try await command("get_prop", coreProps)
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
        if let backgroundResult = try? await command("get_prop", backgroundProps),
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

        if let mainPowerResult = try? await command("get_prop", ["main_power"]),
           let mainPower = mainPowerResult.first {
            state = YeelightStateMapper.applyProps(
                ["main_power": mainPower],
                to: state,
                hasMainPower: &hasMainPowerProperty)
        }
        if let supportResult = try? await command("get_prop", ["support"]),
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
