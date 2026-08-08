import Foundation
import Network
import Combine

/// TCP JSON client for the Yeelight LAN control protocol (port 55443).
///
/// Commands are newline-terminated JSON `{"id":N,"method":"...","params":[...]}`.
/// The lamp answers with `{"id":N,"result":[...]}` and asynchronously pushes
/// `{"method":"props","params":{...}}` notifications.
///
/// All `@Published` state mutations happen on the main thread to avoid racing
/// Combine's `objectWillChange` (a background `@Published` write concurrent
/// with a main-thread one can deadlock the publisher's internal lock).
final class YeelightClient: ObservableObject, @unchecked Sendable {
    @Published var state = LightState()
    @Published var isConnected = false

    static let defaultPort: NWEndpoint.Port = 55443
    static let defaultHost = "192.168.3.111"

    var host: String {
        didSet {
            guard oldValue != host else { return }
            UserDefaults.standard.set(host, forKey: "deviceIP")
            // Recreate the UDP session for the new address even when it is not
            // connected yet; ChromaSession.host is immutable, so keeping the old
            // instance would make the channel talk to the previous IP forever.
            let wasRunning = chroma.isRunning
            chroma.stop()
            chroma = ChromaSession(host: host)
            if wasRunning { chroma.start() }
            connectNow()
        }
    }

    /// Alternative low-latency control channel (UDP 55444 token session).
    /// Republished so the UI can observe connection-state changes.
    @Published var chroma: ChromaSession {
        didSet { bindChroma() }
    }
    @Published private(set) var chromaConnected = false

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "yeelight.client.queue")
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (Result<[Any], Error>) -> Void] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var generation = 0
    private var chromaCancellable: AnyCancellable?

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
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
        }
    }

    private func connectNow() {
        reconnectTask?.cancel()
        reconnectTask = nil
        generation += 1
        let gen = generation
        connection?.cancel()

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: Self.defaultPort,
            using: .tcp
        )
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, gen == self.generation else { return }
            switch state {
            case .ready:
                self.onReady(gen: gen)
            case .waiting(let error):
                // transient: the path will recover on its own; only guard against
                // getting stuck in waiting forever.
                Logger.log("conn gen \(gen): waiting (\(error))")
                self.scheduleWaitingWatchdog(gen: gen)
            case .failed(let error):
                Logger.log("conn gen \(gen): failed (\(error))")
                self.onFailure(gen: gen)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func onReady(gen: Int) {
        guard gen == generation else { return }
        watchdogTask?.cancel()
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = true
            Logger.log("connected to \(self?.host ?? "")")
        }
        receiveLoop(gen: gen)
        Task { @MainActor [weak self] in
            guard gen == self?.generation else { return }
            do {
                try await self?.refresh()
                Logger.log("state: power=\(self?.state.power ?? false) bright=\(self?.state.bright ?? 0) ct=\(self?.state.ct ?? 0) bgPower=\(self?.state.bgPower ?? false) bgRGB=\(self?.state.bgRGB ?? 0)")
            } catch {
                Logger.log("refresh failed: \(error)")
            }
        }
    }

    private func onFailure(gen: Int) {
        guard gen == generation else { return }
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
        }
        failAllPending()
        scheduleReconnect(gen: gen)
    }

    private func scheduleReconnect(gen: Int) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, gen == self.generation else { return }
            self.connectNow()
        }
    }

    /// If the connection lingers in `.waiting`/`.preparing` for too long
    /// (e.g. the device is unreachable), force a fresh attempt.
    private func scheduleWaitingWatchdog(gen: Int) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
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
            DispatchQueue.main.async { [weak self] in
                self?.applyProps(params)
            }
            return
        }

        guard let id = object["id"] as? Int, let handler = pending.removeValue(forKey: id) else { return }
        if let result = object["result"] as? [Any] {
            DispatchQueue.main.async { handler(.success(result)) }
        } else if let error = object["error"] as? [String: Any],
                  let message = error["message"] as? String {
            DispatchQueue.main.async {
                handler(.failure(NSError(domain: "yeelight", code: -1,
                                         userInfo: [NSLocalizedDescriptionKey: message])))
            }
        } else {
            DispatchQueue.main.async {
                handler(.failure(NSError(domain: "yeelight", code: -2,
                                         userInfo: [NSLocalizedDescriptionKey: "无法解析响应"])))
            }
        }
    }

    private func failAllPending() {
        let handlers = pending
        pending.removeAll()
        let error = NSError(domain: "yeelight", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "连接已断开"])
        for handler in handlers.values {
            DispatchQueue.main.async { handler(.failure(error)) }
        }
    }

    // MARK: - Commands

    @discardableResult
    func command(_ method: String, _ params: [Any]) async throws -> [Any] {
        let id = nextID
        nextID += 1
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var text = String(data: data, encoding: .utf8)
        else {
            throw NSError(domain: "yeelight", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "命令编码失败"])
        }
        text += "\r\n"

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let conn = self.connection, conn.state == .ready else {
                    continuation.resume(throwing: NSError(
                        domain: "yeelight", code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "未连接设备"]))
                    return
                }
                self.pending[id] = { result in
                    continuation.resume(with: result)
                }
                let timeout = DispatchWorkItem { [weak self] in
                    self?.queue.async {
                        if let handler = self?.pending.removeValue(forKey: id) {
                            DispatchQueue.main.async {
                                handler(.failure(NSError(
                                    domain: "yeelight", code: -6,
                                    userInfo: [NSLocalizedDescriptionKey: "命令超时"])))
                            }
                        }
                    }
                }
                self.queue.asyncAfter(deadline: .now() + 8, execute: timeout)
                conn.send(content: Data(text.utf8), completion: .contentProcessed { error in
                    if let error {
                        timeout.cancel()
                        self.queue.async {
                            self.pending.removeValue(forKey: id)
                            continuation.resume(throwing: error)
                        }
                    }
                })
            }
        }
    }

    // MARK: - Convenience API

    func setPower(_ on: Bool) async throws {
        _ = try await command("set_power", [on ? "on" : "off", "smooth", 500])
        if !on {
            // The lamp sometimes acknowledges set_power off but stays on;
            // verify and fall back to dev_toggle.
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let result = try? await command("get_prop", ["power"]),
               (result.first as? String) == "on" {
                _ = try await command("dev_toggle", [])
            }
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

    // MARK: - Timer (cron)

    /// Schedule a power-off after `minutes` (device-side, in 30-minute units).
    func setCronOff(afterMinutes minutes: Int) async throws {
        let units = min(24, max(1, Int(round(Double(minutes) / 30))))
        _ = try await command("cron_add", [0, units, 0])
    }

    /// Remaining delay in minutes of the scheduled power-off, or nil.
    func getCronOffDelayMinutes() async throws -> Int? {
        let result = try await command("cron_get", [0])
        guard let entry = result.first as? [String: Any],
              let delay = entry["delay"] as? Int else { return nil }
        return delay * 30
    }

    func cancelCronOff() async throws {
        _ = try await command("cron_del", [0])
    }

    // MARK: - Color flow

    /// Run an animated color flow on the backlight. Expression format:
    /// "duration, mode, value, brightness" steps joined by ";".
    /// (mode 1 = RGB color, 2 = CT, 3 = HSV)
    /// Passes count 0 so the flow repeats until `stopBGColorFlow()` is called.
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

    /// Set the RGB color of backlight segment range [start, end].
    /// Segment indexing/layout is device-dependent; verify visually.
    func setSegmentRGB(start: Int, end: Int, rgb: Int) async throws {
        _ = try await command("set_segment_rgb", [start, end, rgb, "smooth", 300])
    }

    @MainActor
    func refresh() async throws {
        let props = ["power", "bright", "ct", "color_mode",
                     "bg_power", "bg_bright", "bg_rgb", "bg_ct", "name"]
        let result = try await command("get_prop", props)
        guard result.count >= props.count else { return }

        var updated = state
        updated.power = (result[0] as? String) == "on"
        updated.bright = Self.int(result[1], fallback: updated.bright)
        updated.ct = Self.int(result[2], fallback: updated.ct)
        updated.colorMode = Self.int(result[3], fallback: updated.colorMode)
        updated.bgPower = (result[4] as? String) == "on"
        updated.bgBright = Self.int(result[5], fallback: updated.bgBright)
        updated.bgRGB = Self.int(result[6], fallback: updated.bgRGB)
        updated.bgCt = Self.int(result[7], fallback: updated.bgCt)
        updated.name = (result[8] as? String) ?? ""
        state = updated
    }

    // MARK: - State mapping

    private func applyProps(_ params: [String: Any]) {
        var updated = state
        if let value = Self.string(params["power"]) { updated.power = value == "on" }
        if let value = Self.intOrNil(params["bright"]) { updated.bright = value }
        if let value = Self.intOrNil(params["ct"]) { updated.ct = value }
        if let value = Self.intOrNil(params["color_mode"]) { updated.colorMode = value }
        if let value = Self.string(params["bg_power"]) { updated.bgPower = value == "on" }
        if let value = Self.intOrNil(params["bg_bright"]) { updated.bgBright = value }
        if let value = Self.intOrNil(params["bg_rgb"]) { updated.bgRGB = value }
        if let value = Self.intOrNil(params["bg_ct"]) { updated.bgCt = value }
        if let value = Self.string(params["name"]) { updated.name = value }
        state = updated
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func int(_ value: Any?, fallback: Int) -> Int {
        return intOrNil(value) ?? fallback
    }

    private static func intOrNil(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
