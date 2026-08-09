import Foundation
import Network

typealias YeelightCommandHandler = @MainActor (String, [Any]) async throws -> [Any]

/// Main-actor-owned TCP adapter. It contains only connection lifecycle,
/// framing, request correlation, and retry/timeout behavior; typed device
/// policy remains in YeelightClient.
@MainActor
final class YeelightTCPTransport: ObservableObject {
    @Published private(set) var isConnected = false
    private static let port = NWEndpoint.Port(rawValue: 55443)!
    let host: String
    var onProperties: (@MainActor ([String: Any]) -> Void)?
    var onReady: (@MainActor () async throws -> Void)?

    private let commandHandler: YeelightCommandHandler?
    private var connection: NWConnection?
    private var buffer = Data()
    private var nextID = 1
    private struct CommandResult: @unchecked Sendable { let values: [Any] }
    private struct PendingCommand {
        let handler: (Result<CommandResult, Error>) -> Void
        let timeout: DispatchWorkItem
    }
    private var pending: [Int: PendingCommand] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var generation = 0

    init(host: String, commandHandler: YeelightCommandHandler? = nil) {
        self.host = host
        self.commandHandler = commandHandler
    }

    func start() { connectNow() }

    func disconnect() {
        generation += 1
        reconnectTask?.cancel(); reconnectTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        connection?.cancel(); connection = nil
        buffer.removeAll(keepingCapacity: false)
        failAllPending(with: "连接已断开")
        isConnected = false
    }

    func send(_ request: YeelightRequest) async throws -> [Any] {
        if let commandHandler { return try await commandHandler(request.method, request.params) }
        let id = nextID
        nextID += 1
        let data = try YeelightProtocol.commandLine(
            id: id, method: request.method, params: request.params)
        let result: CommandResult = try await withCheckedThrowingContinuation { continuation in
            guard let conn = connection, conn.state == .ready else {
                continuation.resume(throwing: NSError(
                    domain: "yeelight", code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "未连接设备"]))
                return
            }
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, let command = self.pending.removeValue(forKey: id) else { return }
                command.handler(.failure(NSError(
                    domain: "yeelight", code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "命令超时"])))
            }
            pending[id] = PendingCommand(
                handler: { result in continuation.resume(with: result) }, timeout: timeout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard let self, let command = self.pending.removeValue(forKey: id) else { return }
                    command.timeout.cancel(); command.handler(.failure(error))
                }
            })
        }
        return result.values
    }

    private func connectNow() {
        reconnectTask?.cancel(); reconnectTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        generation += 1
        let gen = generation
        connection?.cancel(); connection = nil
        buffer.removeAll(keepingCapacity: false)
        failAllPending(with: "连接已重置")
        isConnected = false
        let conn = NWConnection(
            host: NWEndpoint.Host(host), port: Self.port, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in self?.handleConnectionState(state, gen: gen) }
        }
        conn.start(queue: .main)
    }

    private func handleConnectionState(_ state: NWConnection.State, gen: Int) {
        guard gen == generation else { return }
        switch state {
        case .ready:
            watchdogTask?.cancel(); isConnected = true
            Logger.log("connected to \(host)")
            receiveLoop(gen: gen)
            Task { @MainActor [weak self] in
                do { try await self?.onReady?() }
                catch { Logger.log("refresh failed: \(error)") }
            }
        case .waiting(let error):
            Logger.log("conn gen \(gen): waiting (\(error))")
            scheduleWaitingWatchdog(gen: gen)
        case .failed(let error):
            Logger.log("conn gen \(gen): failed (\(error))"); onFailure(gen: gen)
        case .cancelled:
            if connection != nil { onFailure(gen: gen) }
        default: break
        }
    }

    private func onFailure(gen: Int) {
        guard gen == generation else { return }
        generation += 1; connection?.cancel(); connection = nil
        buffer.removeAll(keepingCapacity: false); isConnected = false
        failAllPending(with: "连接已断开")
        let reconnectGeneration = generation
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.generation == reconnectGeneration else { return }
            self.connectNow()
        }
    }

    private func scheduleWaitingWatchdog(gen: Int) {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, let self, gen == self.generation,
                  self.connection?.state != .ready else { return }
            Logger.log("conn gen \(gen): stuck, reconnecting"); self.connectNow()
        }
    }

    private func receiveLoop(gen: Int) {
        guard gen == generation else { return }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                if let data, !data.isEmpty { self.buffer.append(data); self.processBuffer() }
                if complete || error != nil { self.onFailure(gen: gen) } else { self.receiveLoop(gen: gen) }
            }
        }
    }

    private func processBuffer() {
        let separator = Data("\r\n".utf8)
        while let range = buffer.range(of: separator) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty { handleLine(text) }
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let method = object["method"] as? String, method == "props",
           let params = object["params"] as? [String: Any] {
            onProperties?(params); return
        }
        guard let id = Self.intOrNil(object["id"]), let command = pending.removeValue(forKey: id) else { return }
        command.timeout.cancel()
        if let result = object["result"] as? [Any] {
            command.handler(.success(CommandResult(values: result)))
        } else if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            command.handler(.failure(NSError(domain: "yeelight", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])))
        } else {
            command.handler(.failure(NSError(domain: "yeelight", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "无法解析响应"])))
        }
    }

    private func failAllPending(with message: String) {
        let commands = pending; pending.removeAll()
        let error = NSError(domain: "yeelight", code: -3,
            userInfo: [NSLocalizedDescriptionKey: message])
        for command in commands.values { command.timeout.cancel(); command.handler(.failure(error)) }
    }

    private static func intOrNil(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
