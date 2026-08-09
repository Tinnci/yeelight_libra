import Foundation
import Combine
import AppKit

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

/// Owns the automatic modes: cinema (one-tap immersive bias lighting),
/// circadian (main-light CT/brightness following the time of day), screen
/// color sync, plus the automation group: sunrise wake-up, scheduled
/// scenes, and display sleep/wake linkage.
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

    // MARK: - Sunrise wake-up

    @Published var wakeUpEnabled = false {
        didSet { handleWakeUpChange() }
    }
    @Published var wakeUpAlarmDate = Date() {
        didSet {
            persistWakeUpTime()
            syncWakeUpConfig()
            if wakeUpEnabled { startWakeUp() }
        }
    }
    @Published var wakeUpRampMinutes = 30 {
        didSet {
            persistWakeUpRamp()
            syncWakeUpConfig()
            if wakeUpEnabled { startWakeUp() }
        }
    }
    @Published private(set) var wakeUpStatusText = ""
    @Published private(set) var wakeUpProgress: Double?

    // MARK: - Scheduled scenes

    @Published var sceneSchedule = SceneSchedule.defaultSchedule() {
        didSet { persistSceneSchedule() }
    }

    // MARK: - Display sleep/wake linkage

    @Published var displayLinkEnabled = false {
        didSet { handleDisplayLinkChange() }
    }

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

    private var wakeUpConfig = SunriseWakeUp()
    private var wakeUpTask: Task<Void, Never>?
    private var lastWakeUpWindowDay: Date?
    private var wakeUpPoweredOn = false

    private var scheduleTask: Task<Void, Never>?
    private var scheduleAppliedDays: [Int: Date] = [:]

    private var displaySleepCancellable: AnyCancellable?
    private var displayWakeCancellable: AnyCancellable?
    private var displaySnapshot: LightState?

    // MARK: - Persistence keys

    private static let wakeUpAlarmHourKey = "wakeUpAlarmHour"
    private static let wakeUpAlarmMinuteKey = "wakeUpAlarmMinute"
    private static let wakeUpRampKey = "wakeUpRampMinutes"
    private static let sceneScheduleKey = "sceneSchedules"
    private static let displayLinkKey = "displayLinkEnabled"

    init(client: YeelightClient) {
        self.client = client
        let defaults = UserDefaults.standard
        let calendar = Calendar.current
        let hour = defaults.object(forKey: Self.wakeUpAlarmHourKey) as? Int ?? 7
        let minute = defaults.object(forKey: Self.wakeUpAlarmMinuteKey) as? Int ?? 0
        let ramp = defaults.object(forKey: Self.wakeUpRampKey) as? Int ?? 30
        let now = Date()
        let base = calendar.startOfDay(for: now)
        wakeUpAlarmDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? now
        wakeUpRampMinutes = ramp
        wakeUpConfig = SunriseWakeUp(alarmHour: hour, alarmMinute: minute, rampMinutes: ramp)
        if let data = defaults.data(forKey: Self.sceneScheduleKey),
           let decoded = try? JSONDecoder().decode(SceneSchedule.self, from: data) {
            sceneSchedule = decoded
        } else {
            sceneSchedule = .defaultSchedule()
        }
        displayLinkEnabled = defaults.bool(forKey: Self.displayLinkKey)
        startScheduleLoop()
        if displayLinkEnabled {
            handleDisplayLinkChange()
        }
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
            if wakeUpEnabled { wakeUpEnabled = false }
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

    // MARK: - Sunrise wake-up

    static let wakeUpTickNanos: UInt64 = 15 * 1_000_000_000

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func handleWakeUpChange() {
        if wakeUpEnabled {
            if circadianEnabled { circadianEnabled = false }
            startWakeUp()
        } else {
            wakeUpTask?.cancel()
            wakeUpTask = nil
            wakeUpStatusText = ""
            wakeUpProgress = nil
            wakeUpPoweredOn = false
            lastWakeUpWindowDay = nil
        }
    }

    private func startWakeUp() {
        wakeUpTask?.cancel()
        wakeUpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.evaluateWakeUp()
                try? await Task.sleep(nanoseconds: Self.wakeUpTickNanos)
            }
        }
    }

    @MainActor
    private func evaluateWakeUp() async {
        guard let client, wakeUpEnabled else { return }
        let now = Date()
        let calendar = Calendar.current
        let occurrence = wakeUpConfig.nextOccurrence(after: now, calendar: calendar)
        switch occurrence.phase {
        case .awaiting:
            wakeUpPoweredOn = false
            lastWakeUpWindowDay = nil
            let end = wakeUpConfig.windowEnd(on: occurrence.day, calendar: calendar)
            let text = "等待唤醒 \(Self.timeFormatter.string(from: end))"
            if wakeUpStatusText != text { wakeUpStatusText = text }
            if wakeUpProgress != nil { wakeUpProgress = nil }
            let start = wakeUpConfig.windowStart(on: occurrence.day, calendar: calendar)
            let delay = min(max(start.timeIntervalSince(now), 1), 60)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        case .ramping:
            let day = calendar.startOfDay(for: occurrence.day)
            if lastWakeUpWindowDay != day {
                lastWakeUpWindowDay = day
                wakeUpPoweredOn = false
            }
            // Force the main light on once at window start; afterwards only
            // ramp brightness/CT and never fight a manual power-off.
            if !wakeUpPoweredOn {
                do {
                    try await client.setPower(true)
                    wakeUpPoweredOn = true
                } catch {
                    Logger.log("wake-up power on failed: \(error)")
                }
            }
            guard let progress = wakeUpConfig.progress(at: now, on: day, calendar: calendar) else { return }
            let target = wakeUpConfig.target(progress: progress)
            if wakeUpProgress != progress { wakeUpProgress = progress }
            let percent = Int((progress * 100).rounded())
            let text = "唤醒中 \(percent)%"
            if wakeUpStatusText != text { wakeUpStatusText = text }
            // Only send when the change is meaningful (bright >= 1, ct >= 10).
            guard abs(target.bright - client.state.bright) >= 1 ||
                  abs(target.ct - client.state.ct) >= 10 else { return }
            do {
                try await client.setBright(target.bright)
                try await client.setCT(target.ct)
            } catch {
                Logger.log("wake-up apply failed: \(error)")
            }
        }
    }

    private func persistWakeUpTime() {
        let calendar = Calendar.current
        UserDefaults.standard.set(
            calendar.component(.hour, from: wakeUpAlarmDate),
            forKey: Self.wakeUpAlarmHourKey)
        UserDefaults.standard.set(
            calendar.component(.minute, from: wakeUpAlarmDate),
            forKey: Self.wakeUpAlarmMinuteKey)
    }

    private func persistWakeUpRamp() {
        UserDefaults.standard.set(wakeUpRampMinutes, forKey: Self.wakeUpRampKey)
    }

    private func syncWakeUpConfig() {
        let calendar = Calendar.current
        wakeUpConfig.alarmHour = calendar.component(.hour, from: wakeUpAlarmDate)
        wakeUpConfig.alarmMinute = calendar.component(.minute, from: wakeUpAlarmDate)
        wakeUpConfig.rampMinutes = wakeUpRampMinutes
    }

    // MARK: - Scheduled scenes

    static let scheduleTickNanos: UInt64 = 30 * 1_000_000_000

    private func startScheduleLoop() {
        scheduleTask?.cancel()
        scheduleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.evaluateSceneSchedule()
                try? await Task.sleep(nanoseconds: Self.scheduleTickNanos)
            }
        }
    }

    /// Applies each enabled entry once per day (tracked per entry, so an early
    /// slot like 19:00 never suppresses a later slot like 23:00).
    @MainActor
    private func evaluateSceneSchedule() async {
        guard let client else { return }
        let now = Date()
        let calendar = Calendar.current
        let stale = scheduleAppliedDays.filter { !calendar.isDate($0.value, inSameDayAs: now) }
        for key in stale.keys {
            scheduleAppliedDays.removeValue(forKey: key)
        }
        for entry in sceneSchedule.entries {
            guard sceneSchedule.isDue(
                entry, at: now,
                appliedOn: scheduleAppliedDays[entry.id],
                calendar: calendar
            ) else { continue }
            guard let scene = ScenePreset.all.first(where: { $0.name == entry.sceneName }) else { continue }
            if circadianEnabled { circadianEnabled = false }
            if wakeUpEnabled { wakeUpEnabled = false }
            userTookBacklightControl()
            do {
                try await client.applyScene(scene)
                scheduleAppliedDays[entry.id] = calendar.startOfDay(for: now)
            } catch {
                Logger.log("scheduled scene apply failed: \(error)")
            }
        }
    }

    private func persistSceneSchedule() {
        if let data = try? JSONEncoder().encode(sceneSchedule) {
            UserDefaults.standard.set(data, forKey: Self.sceneScheduleKey)
        }
    }

    // MARK: - Display sleep/wake linkage

    private func handleDisplayLinkChange() {
        let center = NSWorkspace.shared.notificationCenter
        if displayLinkEnabled {
            displaySleepCancellable = center
                .publisher(for: NSWorkspace.screensDidSleepNotification)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.displayDidSleep() }
                }
            displayWakeCancellable = center
                .publisher(for: NSWorkspace.screensDidWakeNotification)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.displayDidWake() }
                }
        } else {
            displaySleepCancellable?.cancel()
            displaySleepCancellable = nil
            displayWakeCancellable?.cancel()
            displayWakeCancellable = nil
            displaySnapshot = nil
        }
    }

    @MainActor
    private func displayDidSleep() {
        guard let client else { return }
        guard client.state.power || client.state.bgPower else { return }
        displaySnapshot = client.state
        Task { [weak client] in
            guard let client else { return }
            do {
                try await client.setPower(false)
                try await client.setBGPower(false)
            } catch {
                Logger.log("display sleep off failed: \(error)")
            }
        }
    }

    @MainActor
    private func displayDidWake() {
        let snapshot = displaySnapshot
        displaySnapshot = nil
        guard let snapshot, let client else { return }
        Task { [weak self, weak client] in
            guard let self, let client else { return }
            do {
                try await self.restore(snapshot, client: client)
            } catch {
                Logger.log("display wake restore failed: \(error)")
            }
        }
    }

    // MARK: - Lifecycle

    func stop() {
        circadianTask?.cancel()
        circadianTask = nil
        screenSyncTask?.cancel()
        screenSyncTask = nil
        wakeUpTask?.cancel()
        wakeUpTask = nil
        scheduleTask?.cancel()
        scheduleTask = nil
        displaySleepCancellable?.cancel()
        displaySleepCancellable = nil
        displayWakeCancellable?.cancel()
        displayWakeCancellable = nil
    }
}
