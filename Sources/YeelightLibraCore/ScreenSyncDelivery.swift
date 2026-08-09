import Foundation

/// A send decision produced by the screen-sync coalescer.
enum ScreenSyncSend: Equatable {
    case chroma(RGB)
    case tcp(RGB)
}

/// Owns color hysteresis, TCP throttling, and the latest-value queue used by
/// screen synchronization. A color is considered delivered only when a
/// Chroma datagram is accepted for sending or a TCP request is started.
struct ScreenSyncDelivery {
    private(set) var lastDelivered: RGB?

    private var pending: RGB?
    private var tcpInFlight = false
    private var tcpInFlightColor: RGB?
    private var lastTCPStart = Date.distantPast
    private let tcpInterval: TimeInterval

    init(tcpInterval: TimeInterval = 0.5) {
        self.tcpInterval = tcpInterval
    }

    var hasPendingTCP: Bool { pending != nil }

    func tcpDelay(now: Date) -> TimeInterval? {
        guard pending != nil, !tcpInFlight else { return nil }
        return max(0, tcpInterval - now.timeIntervalSince(lastTCPStart))
    }

    mutating func offer(
        _ rgb: RGB,
        now: Date,
        chromaAvailable: Bool
    ) -> ScreenSyncSend? {
        if let pending, !ScreenColorSampler.shouldSend(current: pending, next: rgb) {
            return drain(now: now, chromaAvailable: chromaAvailable)
        }
        guard ScreenColorSampler.shouldSend(current: lastDelivered, next: rgb) else {
            return nil
        }
        pending = rgb
        return drain(now: now, chromaAvailable: chromaAvailable)
    }

    /// Completes the currently active TCP request and, if possible, starts the
    /// newest queued color immediately. A failed request is re-queued.
    mutating func finishTCP(
        succeeded: Bool,
        now: Date,
        chromaAvailable: Bool
    ) -> ScreenSyncSend? {
        guard tcpInFlight else { return nil }
        tcpInFlight = false
        if !succeeded, let tcpInFlightColor {
            pending = tcpInFlightColor
            lastDelivered = nil
        }
        tcpInFlightColor = nil
        return drain(now: now, chromaAvailable: chromaAvailable)
    }

    mutating func flush(now: Date, chromaAvailable: Bool) -> ScreenSyncSend? {
        drain(now: now, chromaAvailable: chromaAvailable)
    }

    mutating func reset() {
        lastDelivered = nil
        pending = nil
        tcpInFlight = false
        tcpInFlightColor = nil
        lastTCPStart = .distantPast
    }

    private mutating func drain(now: Date, chromaAvailable: Bool) -> ScreenSyncSend? {
        guard let pending else { return nil }
        if chromaAvailable {
            self.pending = nil
            lastDelivered = pending
            return .chroma(pending)
        }
        guard !tcpInFlight,
              now.timeIntervalSince(lastTCPStart) >= tcpInterval else { return nil }
        self.pending = nil
        tcpInFlight = true
        tcpInFlightColor = pending
        lastTCPStart = now
        lastDelivered = pending
        return .tcp(pending)
    }
}
