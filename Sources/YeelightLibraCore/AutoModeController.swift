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
@MainActor
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
        didSet {
            store.set(displayLinkEnabled, forKey: Self.displayLinkKey)
            handleDisplayLinkChange()
        }
    }

    let schedule = CircadianSchedule.default

    private weak var client: YeelightClient?
    private var circadianTask: Task<Void, Never>?
    private var cinemaSnapshot: LightState?
    private let screenSampler: any ScreenSampling
    private let store: any AutomationStore
    private let clock: any AutomationClock
    private let displayEvents: any DisplayEventSource
    private var screenSyncTask: Task<Void, Never>?
    private var screenSnapshot: LightState?
    private var screenDelivery = ScreenSyncDelivery()
    private var screenFlushTask: Task<Void, Never>?
    private var unchangedCount = 0
    private var cinemaGeneration = 0
    private var screenSyncGeneration = 0
    private var circadianGeneration = 0
    private var wakeUpGeneration = 0
    private var suppressCinemaRestore = false
    private var suppressScreenSyncRestore = false
    private var automationArbitration = AutomationArbitration()

    private var wakeUpConfig = SunriseWakeUp()
    private var wakeUpTask: Task<Void, Never>?
    private var lastWakeUpWindowDay: Date?
    private var wakeUpPoweredOn = false

    private var scheduleTask: Task<Void, Never>?
    private var scheduleAppliedDays: [Int: Date] = [:]

    private var displaySleepCancellable: AnyCancellable?
    private var displayWakeCancellable: AnyCancellable?
    private var displaySnapshot: LightState?
    private var displayTask: Task<Void, Never>?
    private var displayState = DisplayLinkState()

    // MARK: - Persistence keys

    private static let wakeUpAlarmHourKey = "wakeUpAlarmHour"
    private static let wakeUpAlarmMinuteKey = "wakeUpAlarmMinute"
    private static let wakeUpRampKey = "wakeUpRampMinutes"
    private static let sceneScheduleKey = "sceneSchedules"
    private static let sceneScheduleAppliedDaysKey = "sceneScheduleAppliedDays"
    private static let displayLinkKey = "displayLinkEnabled"

    init(
        client: YeelightClient,
        store: any AutomationStore = UserDefaultsAutomationStore(),
        clock: any AutomationClock = SystemAutomationClock(),
        screenSampler: any ScreenSampling = ScreenColorSampler(),
        displayEvents: any DisplayEventSource = WorkspaceDisplayEventSource()
    ) {
        self.client = client
        self.store = store
        self.clock = clock
        self.screenSampler = screenSampler
        self.displayEvents = displayEvents
        let calendar = clock.calendar
        let hour = store.int(forKey: Self.wakeUpAlarmHourKey) ?? 7
        let minute = store.int(forKey: Self.wakeUpAlarmMinuteKey) ?? 0
        let ramp = store.int(forKey: Self.wakeUpRampKey) ?? 30
        let now = clock.now
        let base = calendar.startOfDay(for: now)
        wakeUpAlarmDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? now
        wakeUpRampMinutes = ramp
        wakeUpConfig = SunriseWakeUp(alarmHour: hour, alarmMinute: minute, rampMinutes: ramp)
        if let data = store.data(forKey: Self.sceneScheduleKey),
           let decoded = try? JSONDecoder().decode(SceneSchedule.self, from: data) {
            sceneSchedule = decoded
        } else {
            sceneSchedule = .defaultSchedule()
        }
        if let data = store.data(forKey: Self.sceneScheduleAppliedDaysKey),
           let decoded = try? JSONDecoder().decode([Int: Date].self, from: data) {
            scheduleAppliedDays = decoded
        }
        displayLinkEnabled = store.bool(forKey: Self.displayLinkKey)
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
        FlowExpression.cinema
    }()

    private func handleCinemaChange() {
        guard let client else { return }
        applyAutomationIntent(.set(.cinema, enabled: cinemaEnabled))
        cinemaGeneration += 1
        let generation = cinemaGeneration
        if cinemaEnabled {
            cinemaSnapshot = client.state
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.cinemaEnabled,
                      self.cinemaGeneration == generation else { return }
                do {
                    try await client.apply(LightWorkflowPlan(operations: [
                        .setPower(true),
                        .setBright(Self.cinemaMainBright),
                        .setCT(Self.cinemaMainCT),
                        .setBGPower(true),
                        .setBGBright(30),
                        .startBGFlow(Self.cinemaFlowExpression),
                    ]))
                } catch {
                    Logger.log("cinema enable failed: \(error)")
                }
            }
        } else {
            let snapshot = cinemaSnapshot
            cinemaSnapshot = nil
            let shouldRestore = !suppressCinemaRestore
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.cinemaGeneration == generation,
                      !self.cinemaEnabled else { return }
                do {
                    try await client.stopBGColorFlow()
                    guard self.cinemaGeneration == generation,
                          !self.cinemaEnabled else { return }
                    if shouldRestore, let snapshot {
                        try await client.apply(LightWorkflowPlan.restore(snapshot))
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
            mainPower: snapshot.mainPower,
            mainBright: snapshot.mainPower ? snapshot.bright : nil,
            mainCT: snapshot.mainPower ? snapshot.ct : nil,
            bgPower: snapshot.bgPower,
            bgBright: snapshot.bgPower ? snapshot.bgBright : nil,
            bgRGB: snapshot.bgPower ? snapshot.bgRGB : nil
        )
    }

    private func restore(_ snapshot: LightState, client: YeelightClient) async throws {
        try await client.apply(LightWorkflowPlan.restore(snapshot))
    }

    private func restoreBacklight(_ snapshot: LightState, client: YeelightClient) async throws {
        try await client.apply(LightWorkflowPlan.restoreBacklight(snapshot))
    }

    private func applyAutomationIntent(_ intent: AutomationIntent) {
        let disabled = automationArbitration.apply(intent)
        for mode in disabled {
            switch mode {
            case .cinema where cinemaEnabled:
                suppressCinemaRestore = true
                cinemaEnabled = false
                suppressCinemaRestore = false
            case .screenSync where screenSyncEnabled:
                suppressScreenSyncRestore = true
                screenSyncEnabled = false
                suppressScreenSyncRestore = false
            case .circadian where circadianEnabled:
                circadianEnabled = false
            case .wakeUp where wakeUpEnabled:
                wakeUpEnabled = false
            default:
                break
            }
        }
    }

    // MARK: - Circadian mode

    static let circadianIntervalNanos: UInt64 = 5 * 60 * 1_000_000_000

    private func handleCircadianChange() {
        applyAutomationIntent(.set(.circadian, enabled: circadianEnabled))
        circadianGeneration += 1
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
        let generation = circadianGeneration
        circadianTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.evaluateCircadian(generation: generation)
                try? await self?.clock.sleep(nanoseconds: Self.circadianIntervalNanos)
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
    private func evaluateCircadian(generation: Int) async {
        guard let client, circadianEnabled, circadianGeneration == generation else { return }
        let target = schedule.target(at: clock.now)
        let text = "当前 \(target.ct)K · 亮度 \(target.bright)"
        if circadianTargetText != text {
            circadianTargetText = text
        }
        // Adjust only while the main light is on; never force it on.
        guard client.state.mainPower else { return }
        guard Self.shouldApply(
            targetBright: target.bright, targetCT: target.ct,
            currentBright: client.state.bright, currentCT: client.state.ct
        ) else { return }
        do {
            try await client.setBright(target.bright)
            guard circadianEnabled, circadianGeneration == generation else { return }
            try await client.setCT(target.ct)
        } catch {
            Logger.log("circadian apply failed: \(error)")
        }
    }

    // MARK: - Screen sync mode

    private func handleScreenSyncChange() {
        guard let client else { return }
        applyAutomationIntent(.set(.screenSync, enabled: screenSyncEnabled))
        screenSyncGeneration += 1
        let generation = screenSyncGeneration
        if screenSyncEnabled {
            screenSnapshot = client.state
            if !client.state.bgPower {
                Task { @MainActor [weak self, weak client] in
                    guard let self, let client,
                          self.screenSyncEnabled,
                          self.screenSyncGeneration == generation else { return }
                    try? await client.setBGPower(true)
                    guard self.screenSyncEnabled, self.screenSyncGeneration == generation else { return }
                    try? await client.setBGBright(40)
                }
            }
            startScreenSync(generation: generation)
        } else {
            screenSyncTask?.cancel()
            screenSyncTask = nil
            screenDelivery.reset()
            screenFlushTask?.cancel()
            screenFlushTask = nil
            unchangedCount = 0
            screenSyncColor = nil
            screenSyncStatusText = ""
            let snapshot = screenSnapshot
            screenSnapshot = nil
            let shouldRestore = !suppressScreenSyncRestore
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.screenSyncGeneration == generation,
                      !self.screenSyncEnabled else { return }
                do {
                    try? await client.stopBGColorFlow()
                    guard self.screenSyncGeneration == generation,
                          !self.screenSyncEnabled else { return }
                    if shouldRestore, let snapshot {
                        try await self.restoreBacklight(snapshot, client: client)
                    }
                } catch {
                    Logger.log("screen sync disable failed: \(error)")
                }
            }
        }
    }

    private func startScreenSync(generation: Int) {
        screenSyncTask?.cancel()
        screenSyncTask = Task { @MainActor [weak self] in
            guard let self,
                  self.screenSyncEnabled,
                  self.screenSyncGeneration == generation else { return }
            if !(await self.screenSampler.authorized()) {
                self.screenSyncStatusText = "需要屏幕录制权限（授予后请重启应用）"
            }
            while !Task.isCancelled,
                  self.screenSyncEnabled,
                  self.screenSyncGeneration == generation {
                if let rgb = await self.screenSampler.sampleDisplay() {
                    self.screenSyncColor = rgb
                    if let send = self.screenDelivery.offer(
                        rgb,
                        now: self.clock.now,
                        chromaAvailable: self.client?.chroma.isRunning == true
                            && self.client?.chromaConnected == true
                    ) {
                        self.sendScreenColor(send, generation: generation)
                        self.unchangedCount = 0
                    } else {
                        self.scheduleScreenFlush(generation: generation)
                        self.unchangedCount += 1
                    }
                } else {
                    self.unchangedCount += 1
                }
                let interval: UInt64 = self.unchangedCount >= 10 ? 1_000_000_000 : 200_000_000
                try? await self.clock.sleep(nanoseconds: interval)
            }
        }
    }

    private func sendScreenColor(_ send: ScreenSyncSend, generation: Int) {
        guard let client else { return }
        guard screenSyncEnabled, screenSyncGeneration == generation else { return }
        guard client.state.bgPower else {
            screenDelivery.reset()
            screenSyncStatusText = "背灯已关闭"
            return
        }
        switch send {
        case .chroma(let rgb):
            let value = (rgb.r << 16) | (rgb.g << 8) | rgb.b
            client.chroma.bgSetRGB(value)
            screenSyncStatusText = String(format: "同步中 #%06X", value)
        case .tcp(let rgb):
            let value = (rgb.r << 16) | (rgb.g << 8) | rgb.b
            Task { @MainActor [weak self, weak client] in
                let succeeded: Bool
                do {
                    try await client?.setBGRGB(value)
                    succeeded = client != nil
                } catch {
                    succeeded = false
                    Logger.log("screen sync TCP send failed: \(error)")
                }
                guard let self, self.screenSyncEnabled,
                      self.screenSyncGeneration == generation else { return }
                let chromaAvailable = client?.chroma.isRunning == true
                    && client?.chromaConnected == true
                if let next = self.screenDelivery.finishTCP(
                    succeeded: succeeded,
                    now: self.clock.now,
                    chromaAvailable: chromaAvailable
                ) {
                    self.sendScreenColor(next, generation: generation)
                } else {
                    self.scheduleScreenFlush(generation: generation)
                }
            }
            screenSyncStatusText = String(format: "同步中 #%06X", value)
        }
    }

    private func scheduleScreenFlush(generation: Int) {
        guard screenSyncEnabled, screenSyncGeneration == generation,
              let delay = screenDelivery.tcpDelay(now: clock.now) else { return }
        screenFlushTask?.cancel()
        screenFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, self.screenSyncEnabled,
                  self.screenSyncGeneration == generation else { return }
            let chromaAvailable = self.client?.chroma.isRunning == true
                && self.client?.chromaConnected == true
            if let next = self.screenDelivery.flush(
                now: self.clock.now,
                chromaAvailable: chromaAvailable
            ) {
                self.sendScreenColor(next, generation: generation)
            }
        }
    }

    /// Any manual backlight action (color pick, scene, bg power) hands control
    /// back to the user and tears down the automatic backlight modes.
    func userTookBacklightControl() {
        applyAutomationIntent(.manualBacklightControl)
    }

    /// Any manual main-light action hands control back from all main-light
    /// automations. Disabling through the conflict path prevents an old async
    /// restore from overwriting the user's new value.
    func userTookMainControl() {
        applyAutomationIntent(.manualMainControl)
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
        applyAutomationIntent(.set(.wakeUp, enabled: wakeUpEnabled))
        wakeUpGeneration += 1
        if wakeUpEnabled {
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
        let generation = wakeUpGeneration
        wakeUpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.evaluateWakeUp(generation: generation)
                try? await self?.clock.sleep(nanoseconds: Self.wakeUpTickNanos)
            }
        }
    }

    @MainActor
    private func evaluateWakeUp(generation: Int) async {
        guard let client, wakeUpEnabled, wakeUpGeneration == generation else { return }
        let now = clock.now
        let calendar = clock.calendar
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
            try? await clock.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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
                    guard self.wakeUpEnabled, self.wakeUpGeneration == generation else { return }
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
            guard client.state.mainPower else {
                // Keep the one-shot "powered on" marker. If the user turns
                // the lamp off during the ramp, the next tick must not turn
                // it back on.
                return
            }
            guard abs(target.bright - client.state.bright) >= 1 ||
                  abs(target.ct - client.state.ct) >= 10 else { return }
            do {
                try await client.apply(LightWorkflowPlan(operations: [
                    .setBright(target.bright), .setCT(target.ct)
                ]))
            } catch {
                Logger.log("wake-up apply failed: \(error)")
            }
        }
    }

    private func persistWakeUpTime() {
        let calendar = clock.calendar
        store.set(
            calendar.component(.hour, from: wakeUpAlarmDate),
            forKey: Self.wakeUpAlarmHourKey)
        store.set(
            calendar.component(.minute, from: wakeUpAlarmDate),
            forKey: Self.wakeUpAlarmMinuteKey)
    }

    private func persistWakeUpRamp() {
        store.set(wakeUpRampMinutes, forKey: Self.wakeUpRampKey)
    }

    private func syncWakeUpConfig() {
        let calendar = clock.calendar
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
                try? await self?.clock.sleep(nanoseconds: Self.scheduleTickNanos)
            }
        }
    }

    /// Applies each enabled entry once per day (tracked per entry, so an early
    /// slot like 19:00 never suppresses a later slot like 23:00).
    @MainActor
    private func evaluateSceneSchedule() async {
        guard let client else { return }
        let now = clock.now
        let calendar = clock.calendar
        let stale = scheduleAppliedDays.filter { !calendar.isDate($0.value, inSameDayAs: now) }
        for key in stale.keys {
            scheduleAppliedDays.removeValue(forKey: key)
        }
        if !stale.isEmpty {
            persistSceneScheduleAppliedDays()
        }
        for entry in sceneSchedule.dueEntries(
            at: now,
            appliedDays: scheduleAppliedDays,
            calendar: calendar,
            policy: .latestOnly
        ) {
            guard let scene = ScenePreset.all.first(where: { $0.name == entry.sceneName }) else { continue }
            applyAutomationIntent(.manualMainControl)
            userTookBacklightControl()
            do {
                try await client.applyScene(scene)
                scheduleAppliedDays[entry.id] = calendar.startOfDay(for: now)
                persistSceneScheduleAppliedDays()
            } catch {
                // A workflow can have applied a prefix before failing. Refresh
                // before the next scheduled retry so the retry reconciles with
                // device state instead of assuming the old mirror is exact.
                try? await client.refresh()
                Logger.log("scheduled scene apply failed: \(error)")
            }
        }
    }

    private func persistSceneSchedule() {
        if let data = try? JSONEncoder().encode(sceneSchedule) {
            store.set(data, forKey: Self.sceneScheduleKey)
        }
    }

    private func persistSceneScheduleAppliedDays() {
        if let data = try? JSONEncoder().encode(scheduleAppliedDays) {
            store.set(data, forKey: Self.sceneScheduleAppliedDaysKey)
        }
    }

    // MARK: - Display sleep/wake linkage

    private func handleDisplayLinkChange() {
        if displayLinkEnabled {
            displaySleepCancellable = displayEvents.screensDidSleep
                .sink { [weak self] _ in
                    Task { @MainActor in self?.displayDidSleep() }
                }
            displayWakeCancellable = displayEvents.screensDidWake
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
        guard client.state.mainPower || client.state.bgPower else { return }
        let generation = displayState.beginSleep()
        let previous = displayTask
        displaySnapshot = client.state
        displayTask = Task { @MainActor [weak self, weak client] in
            // Serialize display transitions. Cancellation of a Swift Task does
            // not cancel an already-written network request, so a generation
            // check alone is insufficient; the next transition waits for the
            // previous one to finish before restoring state.
            await previous?.value
            guard let self, let client, self.displayState.owns(generation) else { return }
            do {
                try await client.apply(LightWorkflowPlan(operations: [
                    .setPower(false), .setBGPower(false)
                ]))
            } catch {
                Logger.log("display sleep off failed: \(error)")
            }
        }
    }

    @MainActor
    private func displayDidWake() {
        let snapshot = displaySnapshot
        displaySnapshot = nil
        let generation = displayState.beginWake()
        let previous = displayTask
        guard let snapshot, let client else { return }
        displayTask = Task { @MainActor [weak self, weak client] in
            guard let self, let client else { return }
            await previous?.value
            guard self.displayState.owns(generation) else { return }
            do {
                try await self.restore(snapshot, client: client)
            } catch {
                Logger.log("display wake restore failed: \(error)")
            }
        }
    }

    // MARK: - Lifecycle

    func stop() {
        displayState.stop()
        displayTask?.cancel()
        displayTask = nil
        displaySnapshot = nil
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
