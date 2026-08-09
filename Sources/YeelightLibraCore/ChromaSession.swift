import Foundation
import Network
import Combine

/// UDP 55444 token-session control channel — the "Chroma" interface.
///
/// The UDP socket is deliberately owned by the main actor. Network.framework
/// invokes callbacks on its own queue, so every callback hops back before it
/// can mutate the token, liveness state, or pending keep-alive ID.
@MainActor
final class ChromaSession: ObservableObject {
    @Published var isConnected = false

    let host: String
    private static let port = NWEndpoint.Port(rawValue: 55444)!

    private var socket: NWConnection?
    var token = ""
    private var nextID = 1
    private var generation = 0
    private var desiredRunning = false
    private var handshakeTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var keepAliveWatchdog: Task<Void, Never>?
    private var keepAliveID: Int?
    private var reconnectTask: Task<Void, Never>?

    init(host: String) {
        self.host = host
    }

    // MARK: - Session lifecycle

    func start() {
        desiredRunning = true
        guard socket == nil else { return }
        connect()
    }

    /// True while this session is desired, including while it is reconnecting
    /// or waiting for the token handshake.
    var isRunning: Bool { desiredRunning }

    func stop() {
        desiredRunning = false
        generation += 1
        cancelTasks()
        token = ""
        keepAliveID = nil
        socket?.cancel()
        socket = nil
        isConnected = false
    }

    private func connect() {
        guard desiredRunning, socket == nil else { return }
        generation += 1
        let gen = generation
        let conn = NWConnection(host: NWEndpoint.Host(host), port: Self.port, using: .udp)
        socket = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleState(state, generation: gen)
            }
        }
        conn.start(queue: .main)
    }

    private func handleState(_ state: NWConnection.State, generation gen: Int) {
        guard gen == generation, desiredRunning else { return }
        switch state {
        case .ready:
            beginSession(generation: gen)
        case .failed(let error):
            Logger.log("chroma gen \(gen): failed (\(error))")
            sessionFailed(generation: gen)
        case .waiting(let error):
            Logger.log("chroma gen \(gen): waiting (\(error))")
        case .cancelled:
            sessionFailed(generation: gen)
        default:
            break
        }
    }

    private func beginSession(generation gen: Int) {
        guard gen == generation, desiredRunning else { return }
        token = ""
        isConnected = false
        keepAliveID = nil
        send(method: "udp_sess_new", params: [])
        receiveLoop(generation: gen)

        handshakeTask?.cancel()
        handshakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self,
                  gen == self.generation, self.desiredRunning,
                  !self.isConnected else { return }
            Logger.log("chroma gen \(gen): handshake timeout")
            self.sessionFailed(generation: gen)
        }
    }

    private func receiveLoop(generation gen: Int) {
        guard gen == generation, desiredRunning else { return }
        socket?.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation, self.desiredRunning else { return }
                if let data, !data.isEmpty {
                    self.process(data)
                }
                if error != nil {
                    self.sessionFailed(generation: gen)
                } else {
                    self.receiveLoop(generation: gen)
                }
            }
        }
    }

    private func process(_ data: Data) {
        // A datagram normally contains one response, but accepting multiple
        // CRLF-delimited lines makes the parser tolerant of test doubles and
        // implementations that batch responses.
        for line in String(decoding: data, as: UTF8.self)
            .components(separatedBy: "\r\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if let method = object["method"] as? String,
               method == "udp_sess_token",
               let params = object["params"] as? [String: Any],
               let newToken = params["token"] as? String,
               !newToken.isEmpty {
                token = newToken
                isConnected = true
                handshakeTask?.cancel()
                startKeepAlive()
            }

            if let id = Self.intOrNil(object["id"]), id == keepAliveID {
                keepAliveID = nil
                keepAliveWatchdog?.cancel()
                keepAliveWatchdog = nil
            }
        }
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self,
                      self.desiredRunning, !self.token.isEmpty else { return }
                self.sendKeepAlive()
            }
        }
    }

    private func sendKeepAlive() {
        let id = nextMessageID()
        keepAliveID = id
        send(method: "udp_sess_keep_alive",
             params: ["keeplive_interval", "10"], token: token, id: id)
        keepAliveWatchdog?.cancel()
        keepAliveWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self,
                  self.keepAliveID == id else { return }
            Logger.log("chroma keep-alive timeout")
            self.sessionFailed(generation: self.generation)
        }
    }

    private func sessionFailed(generation gen: Int) {
        guard gen == generation else { return }
        // Invalidate callbacks already queued by the old socket before
        // scheduling a replacement session.
        generation += 1
        handshakeTask?.cancel()
        handshakeTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        keepAliveWatchdog?.cancel()
        keepAliveWatchdog = nil
        keepAliveID = nil
        token = ""
        isConnected = false
        socket?.cancel()
        socket = nil

        guard desiredRunning else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.desiredRunning else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    private func cancelTasks() {
        handshakeTask?.cancel()
        handshakeTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        keepAliveWatchdog?.cancel()
        keepAliveWatchdog = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - Control (fire-and-forget)

    static func backlightPowerParameters(on: Bool) -> [Any] {
        [on ? "on" : "off", "smooth", 500]
    }

    func bgSetRGB(_ rgb: Int) {
        guard isConnected else { return }
        send(method: "bg_set_rgb", params: [rgb, "sudden", 0], token: token)
    }

    func bgSetPower(_ on: Bool) {
        guard isConnected else { return }
        send(method: "bg_set_power", params: Self.backlightPowerParameters(on: on), token: token)
    }

    func setSceneColor(rgb: Int, bright: Int) {
        guard isConnected else { return }
        send(method: "set_scene", params: ["color", rgb, bright, 1000, "smooth"], token: token)
    }

    // MARK: - Internal

    private func nextMessageID() -> Int {
        let id = nextID
        nextID += 1
        return id
    }

    private func send(method: String, params: [Any], token: String? = nil, id: Int? = nil) {
        guard let data = try? YeelightProtocol.commandLine(
            id: id ?? nextMessageID(), method: method, params: params, token: token),
              let socket else { return }
        socket.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self, self.desiredRunning else { return }
                Logger.log("chroma send failed: \(error)")
                self.sessionFailed(generation: self.generation)
            }
        })
    }

    private static func intOrNil(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
