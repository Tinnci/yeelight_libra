import Foundation
import Network
import Combine

/// UDP 55444 token-session control channel — the "Chroma" interface.
///
/// Handshake: send `udp_sess_new`, the lamp replies `udp_sess_token` with a
/// token. Control commands are fire-and-forget JSON carrying that token, and
/// `udp_sess_keep_alive` must be sent every ~10s to hold the session.
final class ChromaSession: ObservableObject, @unchecked Sendable {
    @Published var isConnected = false

    let host: String
    private static let port = NWEndpoint.Port(rawValue: 55444)!

    private let queue = DispatchQueue(label: "yeelight.chroma.queue")
    private var socket: NWConnection?
    var token = ""
    private var nextID = 1
    private var generation = 0
    private var keepAliveTask: Task<Void, Never>?

    init(host: String) {
        self.host = host
    }

    // MARK: - Session lifecycle

    func start() {
        guard socket == nil else { return }
        generation += 1
        let gen = generation
        let conn = NWConnection(host: NWEndpoint.Host(host), port: Self.port, using: .udp)
        socket = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, gen == self.generation else { return }
            if state == .ready {
                self.beginSession(gen: gen)
            }
        }
        conn.start(queue: queue)
    }

    /// True while the UDP socket is up, even before the handshake completes.
    var isRunning: Bool { socket != nil }

    func stop() {
        generation += 1
        keepAliveTask?.cancel()
        keepAliveTask = nil
        token = ""
        socket?.cancel()
        socket = nil
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
        }
    }

    private func beginSession(gen: Int) {
        send(json: ["id": nextMessageID(), "method": "udp_sess_new", "params": []])
        receiveLoop(gen: gen)
    }

    private func receiveLoop(gen: Int) {
        guard gen == generation else { return }
        socket?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self, gen == self.generation else { return }
            if let data, !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                self.process(line)
            }
            if error == nil {
                self.receiveLoop(gen: gen)
            }
        }
    }

    private func process(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String
        else { return }

        if method == "udp_sess_token",
           let params = object["params"] as? [String: Any],
           let newToken = params["token"] as? String {
            token = newToken
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = true
            }
            startKeepAlive()
        }
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !self.token.isEmpty else { return }
                self.send(json: [
                    "id": self.nextMessageID(),
                    "method": "udp_sess_keep_alive",
                    "params": ["keeplive_interval", "10"],
                    "token": self.token,
                ])
            }
        }
    }

    // MARK: - Control (fire-and-forget)

    func bgSetRGB(_ rgb: Int) {
        send(json: ["id": nextMessageID(), "method": "bg_set_rgb",
                    "params": [rgb, "sudden", 0], "token": token])
    }

    func bgSetPower(_ on: Bool) {
        send(json: ["id": nextMessageID(), "method": "bg_set_power",
                    "params": [on ? "on" : "off"], "token": token])
    }

    func setSceneColor(rgb: Int, bright: Int) {
        send(json: ["id": nextMessageID(), "method": "set_scene",
                    "params": ["color", rgb, bright, 1000, "smooth"], "token": token])
    }

    // MARK: - Internal

    private func nextMessageID() -> Int {
        let id = nextID
        nextID += 1
        return id
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              var text = String(data: data, encoding: .utf8) else { return }
        text += "\r\n"
        socket?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }
}
