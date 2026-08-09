import Foundation
import Combine

/// A pure description of the commands needed to restore a state snapshot.
/// Channels that were off carry `nil` values and are skipped on restore.
struct LightRestorePlan: Equatable {
    var mainPower: Bool
    var mainBright: Int?
    var mainCT: Int?
    var bgPower: Bool
    var bgBright: Int?
    var bgRGB: Int?
}

/// Owns the two automatic modes: cinema (one-tap immersive bias lighting)
/// and circadian (main-light CT/brightness following the time of day).
/// Created by `AppDelegate` and shared with the menu bar panel.
final class AutoModeController: ObservableObject {
    @Published var cinemaEnabled = false {
        didSet { handleCinemaChange() }
    }
    @Published var circadianEnabled = false {
        didSet { handleCircadianChange() }
    }
    @Published private(set) var circadianTargetText = ""
    @Published var screenSyncEnabled = false {
        didSet { handleScreenSyncChange() }
    }
    @Published private(set) var screenSyncStatusText = ""
    @Published private(set) var screenSyncColor: RGB?

    let schedule = CircadianSchedule.default

    private weak var client: YeelightClient?
    private var circadianTask: Task<Void, Never>?
    private var cinemaSnapshot: LightState?
    private let screenSampler = ScreenColorSampler()
    private var screenSyncTask: Task<Void, Never>?
    private var screenSnapshot: LightState?
    private var lastSentColor: RGB?
    private var tcpSendInFlight = false
    private var lastTCPSendTime = Date.distantPast
    private var unchangedCount = 0

    init(client: YeelightClient) {
        self.client = client
    }

    // MARK: - Cinema mode

    /// Cinema main-light targets: dim and warm so the screen stays dominant.
    static let cinemaMainBright = 25
    static let cinemaMainCT = 3500

    /// Slow ambient bias-lighting flow: 5s steps through muted, low-brightness
    /// tones. `bg_start_cf` expression: "duration_ms, mode, value, brightness"
    /// steps joined by "; " (mode 1 = RGB color, repeat count 0 = infinite).
    static let cinemaFlowExpression = {
        let steps = [0x445588, 0x663366, 0x225566, 0x884455]
            .map { "5000, 1, \($0), 30" }
        return steps.joined(separator: "; ")
    }()

    private func handleCinemaChange() {
        guard let client else { return }
        if cinemaEnabled {
            if screenSyncEnabled { screenSyncEnabled = false }
            cinemaSnapshot = client.state
            Task { [weak client] in
                guard let client else { return }
                do {
                    try await client.setPower(true)
                    try await client.setBright(Self.cinemaMainBright)
                    try await client.setCT(Self.cinemaMainCT)
                    try await client.setBGPower(true)
                    try await client.setBGBright(30)
                    try await client.startBGColorFlow(Self.cinemaFlowExpression)
                } catch {
                    Logger.log("cinema enable failed: \(error)")
                }
            }
        } else {
            let snapshot = cinemaSnapshot
            cinemaSnapshot = nil
            Task { [weak client] in
                guard let client else { return }
                do {
                    try await client.stopBGColorFlow()
                    if let snapshot {
                        try await restore(snapshot, client: client)
                    }
                } catch {
                    Logger.log("cinema disable failed: \(error)")
                }
            }
        }
    }

    /// Map a snapshot to the restore plan; off channels produce `nil` values.
    static func restorePlan(for snapshot: LightState) -> LightRestorePlan {
        LightRestorePlan(
            mainPower: snapshot.power,
            mainBright: snapshot.power ? snapshot.bright : nil,
            mainCT: snapshot.power ? snapshot.ct : nil,
            bgPower: snapshot.bgPower,
            bgBright: snapshot.bgPower ? snapshot.bgBright : nil,
            bgRGB: snapshot.bgPower ? snapshot.bgRGB : nil
        )
    }

    private func restore(_ snapshot: LightState, client: YeelightClient) async throws {
        let plan = Self.restorePlan(for: snapshot)
        try await client.setPower(plan.mainPower)
        if let bright = plan.mainBright { try await client.setBright(bright) }
        if let ct = plan.mainCT { try await client.setCT(ct) }
        try await client.setBGPower(plan.bgPower)
        if let bright = plan.bgBright { try await client.setBGBright(bright) }
        if let rgb = plan.bgRGB { try await client.setBGRGB(rgb) }
    }

    // MARK: - Circadian mode

    static let circadianIntervalNanos: UInt64 = 5 * 60 * 1_000_000_000

    private func handleCircadianChange() {
        if circadianEnabled {
            startCircadian()
        } else {
            circadianTask?.cancel()
            circadianTask = nil
            circadianTargetText = ""
        }
    }

    private func startCircadian() {
        circadianTask?.cancel()
        circadianTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.evaluateCircadian()
                try? await Task.sleep(nanoseconds: Self.circadianIntervalNanos)
            }
        }
    }

    /// Hysteresis: only re-apply when the drift is big enough to matter,
    /// so tiny clock movements do not spam the lamp.
    static func shouldApply(
        targetBright: Int, targetCT: Int,
        currentBright: Int, currentCT: Int
    ) -> Bool {
        abs(targetBright - currentBright) >= 3 || abs(targetCT - currentCT) >= 50
    }

    @MainActor
    private func evaluateCircadian() async {
        guard let client, circadianEnabled else { return }
        let target = schedule.target(at: Date())
        let text = "当前 \(target.ct)K · 亮度 \(target.bright)"
        if circadianTargetText != text {
            circadianTargetText = text
        }
        // Adjust only while the main light is on; never force it on.
        guard client.state.power else { return }
        guard Self.shouldApply(
            targetBright: target.bright, targetCT: target.ct,
            currentBright: client.state.bright, currentCT: client.state.ct
        ) else { return }
        do {
            try await client.setBright(target.bright)
            try await client.setCT(target.ct)
        } catch {
            Logger.log("circadian apply failed: \(error)")
        }
    }

    // MARK: - Screen sync mode

    private func handleScreenSyncChange() {
        guard let client else { return }
        if screenSyncEnabled {
            if cinemaEnabled { cinemaEnabled = false }
            screenSnapshot = client.state
            if !client.state.bgPower {
                Task { [weak client] in
                    guard let client else { return }
                    try? await client.setBGPower(true)
                    try? await client.setBGBright(40)
                }
            }
            startScreenSync()
        } else {
            screenSyncTask?.cancel()
            screenSyncTask = nil
            lastSentColor = nil
            unchangedCount = 0
            tcpSendInFlight = false
            screenSyncColor = nil
            screenSyncStatusText = ""
            let snapshot = screenSnapshot
            screenSnapshot = nil
            Task { [weak client] in
                guard let client else { return }
                do {
                    try? await client.stopBGColorFlow()
                    if let snapshot {
                        try await restore(snapshot, client: client)
                    }
                } catch {
                    Logger.log("screen sync disable failed: \(error)")
                }
            }
        }
    }

    private func startScreenSync() {
        screenSyncTask?.cancel()
        screenSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if !(await self.screenSampler.authorized()) {
                self.screenSyncStatusText = "需要屏幕录制权限（授予后请重启应用）"
            }
            while !Task.isCancelled {
                if let rgb = await self.screenSampler.sampleDisplay() {
                    self.screenSyncColor = rgb
                    if ScreenColorSampler.shouldSend(current: self.lastSentColor, next: rgb) {
                        self.sendScreenColor(rgb)
                        self.lastSentColor = rgb
                        self.unchangedCount = 0
                    } else {
                        self.unchangedCount += 1
                    }
                } else {
                    self.unchangedCount += 1
                }
                let interval: UInt64 = self.unchangedCount >= 10 ? 1_000_000_000 : 200_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func sendScreenColor(_ rgb: RGB) {
        guard let client else { return }
        guard client.state.bgPower else {
            screenSyncStatusText = "背灯已关闭"
            return
        }
        let value = (rgb.r << 16) | (rgb.g << 8) | rgb.b
        if client.chroma.isRunning && client.chromaConnected {
            client.chroma.bgSetRGB(value)
            screenSyncStatusText = String(format: "同步中 #%06X", value)
        } else {
            let now = Date()
            guard !tcpSendInFlight, now.timeIntervalSince(lastTCPSendTime) >= 0.5 else { return }
            tcpSendInFlight = true
            lastTCPSendTime = now
            Task { [weak self, weak client] in
                defer { self?.tcpSendInFlight = false }
                try? await client?.setBGRGB(value)
            }
            screenSyncStatusText = String(format: "同步中 #%06X", value)
        }
    }

    /// Any manual backlight action (color pick, scene, bg power) hands control
    /// back to the user and tears down the automatic backlight modes.
    func userTookBacklightControl() {
        if screenSyncEnabled { screenSyncEnabled = false }
        if cinemaEnabled { cinemaEnabled = false }
    }

    // MARK: - Lifecycle

    func stop() {
        circadianTask?.cancel()
        circadianTask = nil
        screenSyncTask?.cancel()
        screenSyncTask = nil
    }
}
