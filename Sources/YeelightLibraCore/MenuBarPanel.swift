import SwiftUI
import AppKit

/// SwiftUI `Slider` triggers an infinite layout loop when more than one is
/// placed inside a single `NSPopover` on macOS. Wrapping the AppKit-native
/// `NSSlider` avoids that bug entirely.
struct NativeSlider: NSViewRepresentable {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    /// Fired only for user-driven drags, never for programmatic updates.
    /// Sending commands from here (instead of `onChange` of the binding) avoids
    /// echoing commands back when the lamp's `props` notifications move the slider.
    var onUserChange: ((Double) -> Void)?

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        if slider.doubleValue != value.wrappedValue {
            slider.doubleValue = value.wrappedValue
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: NativeSlider

        init(_ parent: NativeSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: NSSlider) {
            parent.value.wrappedValue = sender.doubleValue
            parent.onUserChange?(sender.doubleValue)
        }
    }
}

struct MenuBarPanel: View {
    @ObservedObject var client: YeelightClient
    @ObservedObject var autoController: AutoModeController
    @ObservedObject var controls: LightControlUseCases

    @State private var bright: Double = 10
    @State private var ct: Double = 3200
    @State private var bgBright: Double = 50
    @State private var bgColor: Color = Color(red: 0.8, green: 0.4, blue: 0.5)
    @State private var ipText = YeelightClient.defaultHost
    @State private var mainBrightDebounce: DispatchWorkItem?
    @State private var ctDebounce: DispatchWorkItem?
    @State private var bgBrightDebounce: DispatchWorkItem?
    @State private var colorDebounce: DispatchWorkItem?
    @State private var segmentDebounce: DispatchWorkItem?
    @State private var cronOption = 0
    @State private var segLeft: Color = .orange
    @State private var segRight: Color = .blue
    @AppStorage("chromaUDPEnabled") private var chromaEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            sectionTitle("主灯")
            Toggle(isOn: powerBinding(\.mainPower)) { Text("电源") }
                .toggleStyle(.switch)
            sliderRow("亮度", value: $bright, range: 1...100, schedule: debouncedMain) { value in
                controls.setMainBrightness(Int(value))
            }
            sliderRow("色温", value: $ct, range: 2700...6500, schedule: debouncedCT) { value in
                controls.setMainCT(Int(value))
            }

            Divider()

            sectionTitle("背灯")
            Toggle(isOn: powerBinding(\.bgPower)) { Text("电源") }
                .toggleStyle(.switch)
            sliderRow("亮度", value: $bgBright, range: 1...100, schedule: debouncedBG) { value in
                controls.setBacklightBrightness(Int(value))
            }
            HStack {
                ColorPicker("颜色", selection: $bgColor, supportsOpacity: false)
                    .onChange(of: bgColor) { _, newColor in
                        let rgb = Self.rgbInt(from: newColor)
                        guard rgb != client.state.bgRGB else { return }
                        debouncedColor { sendBGColor(rgb) }
                    }
                Spacer()
                Button("恢复") {
                    debouncedColor { sendBGColor(LightState().bgRGB) }
                }
                .controlSize(.small)
            }
            Divider()

            sectionTitle("场景")
            HStack {
                ForEach(ScenePreset.all) { scene in
                    Button(scene.name) {
                        controls.applyScene(scene)
                    }
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Divider()

            sectionTitle("智能模式")
            Toggle("影院模式", isOn: $autoController.cinemaEnabled)
                .toggleStyle(.switch)
            Toggle("昼夜节律", isOn: $autoController.circadianEnabled)
                .toggleStyle(.switch)
            if !autoController.circadianTargetText.isEmpty {
                Text(autoController.circadianTargetText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("屏幕同步", isOn: $autoController.screenSyncEnabled)
                .toggleStyle(.switch)
            if !autoController.screenSyncStatusText.isEmpty {
                HStack(spacing: 6) {
                    if let syncColor = autoController.screenSyncColor {
                        Circle()
                            .fill(Self.color(fromRGB: (syncColor.r << 16) | (syncColor.g << 8) | syncColor.b))
                            .frame(width: 8, height: 8)
                    }
                    Text(autoController.screenSyncStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("日出唤醒", isOn: $autoController.wakeUpEnabled)
                .toggleStyle(.switch)
            if autoController.wakeUpEnabled {
                HStack(spacing: 8) {
                    Text("唤醒时间").frame(width: 60, alignment: .leading)
                    DatePicker("", selection: $autoController.wakeUpAlarmDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Spacer()
                    Picker("时长", selection: $autoController.wakeUpRampMinutes) {
                        Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30)
                        Text("45 分钟").tag(45)
                        Text("60 分钟").tag(60)
                    }
                    .controlSize(.small)
                }
                if let progress = autoController.wakeUpProgress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                }
                if !autoController.wakeUpStatusText.isEmpty {
                    Text(autoController.wakeUpStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("定时场景", isOn: scheduleMasterBinding)
                .toggleStyle(.switch)
            if autoController.sceneSchedule.entries.contains(where: { $0.enabled }) {
                ForEach(autoController.sceneSchedule.entries.indices, id: \.self) { index in
                    scheduleRow(at: index)
                }
            }
            Toggle("显示器休眠联动", isOn: $autoController.displayLinkEnabled)
                .toggleStyle(.switch)

            Divider()

            sectionTitle("定时与流光")
            Picker("定时关灯", selection: $cronOption) {
                Text("取消").tag(0)
                Text("30 分钟").tag(30)
                Text("1 小时").tag(60)
                Text("2 小时").tag(120)
            }
            .disabled(!client.state.mainPower)
            .onChange(of: cronOption) { _, newValue in
                guard client.state.mainPower else { cronOption = 0; return }
                if newValue == 0 {
                    controls.cancelCronOff()
                } else {
                    controls.setCronOff(afterMinutes: newValue)
                }
            }
            HStack {
                Text("背光流光").frame(width: 66, alignment: .leading)
                Button("呼吸") { startFlow(.breath) }
                Button("彩虹") { startFlow(.rainbow) }
                Button("极光") { startFlow(.aurora) }
                Button("停止") {
                    controls.stopBacklightFlow()
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Divider()

            sectionTitle("分段背光（实验性）")
            HStack {
                ColorPicker("左", selection: $segLeft, supportsOpacity: false)
                    .onChange(of: segLeft) { _, c in
                        debouncedSegment { sendSegment(0, 0, c) }
                    }
                ColorPicker("右", selection: $segRight, supportsOpacity: false)
                    .onChange(of: segRight) { _, c in
                        debouncedSegment { sendSegment(1, 1, c) }
                    }
                Spacer()
                Button("整条") {
                    let c = segLeft
                    debouncedSegment { sendSegment(0, 255, c) }
                }
                .controlSize(.small)
            }
            .disabled(!client.supports("set_segment_rgb"))

            Divider()

            HStack {
                Toggle("Chroma UDP 通道", isOn: $chromaEnabled)
                Spacer()
                statusDot(client.chromaConnected, label: client.chromaConnected ? "已连接" : "未连接")
            }
            .toggleStyle(.switch)

            footer
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            ipText = client.host
            segLeft = Self.color(fromRGB: client.state.bgRGB)
            segRight = Self.color(fromRGB: client.state.bgRGB)
            syncFromState()
            if chromaEnabled { client.chroma.start() }
            Task {
                if client.state.mainPower, let minutes = try? await client.getCronOffDelayMinutes() {
                    cronOption = minutes
                }
            }
        }
        .onChange(of: client.state) { _, _ in
            syncFromState()
        }
        .onChange(of: chromaEnabled) { _, enabled in
            if enabled {
                client.chroma.start()
            } else {
                client.chroma.stop()
            }
        }
    }

    // MARK: - Flow presets

    private enum FlowPreset {
        case breath, rainbow, aurora

        var expression: String {
            switch self {
            case .breath:
                return FlowExpression.breath
            case .rainbow:
                return FlowExpression.rainbow
            case .aurora:
                return FlowExpression.aurora
            }
        }
    }

    private func startFlow(_ preset: FlowPreset) {
        let expression = preset.expression
            controls.startBacklightFlow(expression)
    }

    private func sendBGColor(_ rgb: Int) {
        if chromaEnabled && client.chromaConnected {
            client.chroma.bgSetRGB(rgb)
        } else {
            controls.setBacklightColor(rgb)
        }
    }

    private func sendSegment(_ start: Int, _ end: Int, _ color: Color) {
        let rgb = Self.rgbInt(from: color)
        controls.setSegment(start: start, end: end, rgb: rgb)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(client.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("Yeelight Libra")
                    .font(.headline)
                Spacer()
                Button("刷新") {
                    controls.refresh()
                }
                .controlSize(.small)
            }
            HStack {
                TextField("设备 IP", text: $ipText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(connectToIP)
                Button("连接") { connectToIP() }
                    .controlSize(.small)
            }
            Text(client.isConnected ? "已连接 \(client.host):55443" : "未连接，将自动重连")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("主灯 \(client.state.mainStatusText) · 背灯 \(client.state.bgStatusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            if let error = controls.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Helpers

    private var scheduleMasterBinding: Binding<Bool> {
        Binding(
            get: { autoController.sceneSchedule.entries.contains(where: { $0.enabled }) },
            set: { on in
                for index in autoController.sceneSchedule.entries.indices {
                    autoController.sceneSchedule.entries[index].enabled = on
                }
            }
        )
    }

    private func scheduleTimeBinding(for index: Int) -> Binding<Date> {
        Binding(
            get: {
                let entry = autoController.sceneSchedule.entries[index]
                let calendar = Calendar.current
                return calendar.date(bySettingHour: entry.hour, minute: entry.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let calendar = Calendar.current
                autoController.sceneSchedule.entries[index].hour = calendar.component(.hour, from: date)
                autoController.sceneSchedule.entries[index].minute = calendar.component(.minute, from: date)
            }
        )
    }

    private func scheduleRow(at index: Int) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $autoController.sceneSchedule.entries[index].enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
            DatePicker("", selection: scheduleTimeBinding(for: index), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .controlSize(.small)
            Picker("", selection: $autoController.sceneSchedule.entries[index].sceneName) {
                ForEach(ScenePreset.all) { scene in
                    Text(scene.name).tag(scene.name)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            Spacer()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func statusDot(_ connected: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connected ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        schedule: @escaping (@escaping () -> Void) -> Void,
        send: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Text(label).frame(width: 34, alignment: .leading)
            NativeSlider(value: value, range: range) { newValue in
                schedule { send(newValue) }
            }
            Text("\(Int(value.wrappedValue))")
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func powerBinding(_ keyPath: KeyPath<LightState, Bool>) -> Binding<Bool> {
        Binding(
            get: { client.state[keyPath: keyPath] },
            set: { on in
                if keyPath == \LightState.mainPower {
                    controls.setMainPower(on)
                } else {
                    controls.setBacklightPower(on)
                }
            }
        )
    }

    private func debouncedColor(_ action: @escaping () -> Void) {
        colorDebounce?.cancel()
        let work = DispatchWorkItem { Task { @MainActor in action() } }
        colorDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func debouncedSegment(_ action: @escaping () -> Void) {
        segmentDebounce?.cancel()
        let work = DispatchWorkItem { Task { @MainActor in action() } }
        segmentDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func debouncedMain(_ action: @escaping () -> Void) {
        mainBrightDebounce?.cancel()
        let work = DispatchWorkItem { Task { @MainActor in action() } }
        mainBrightDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func debouncedCT(_ action: @escaping () -> Void) {
        ctDebounce?.cancel()
        let work = DispatchWorkItem { Task { @MainActor in action() } }
        ctDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func debouncedBG(_ action: @escaping () -> Void) {
        bgBrightDebounce?.cancel()
        let work = DispatchWorkItem { Task { @MainActor in action() } }
        bgBrightDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func connectToIP() {
        let trimmed = ipText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        client.host = trimmed
    }

    private func syncFromState() {
        let st = client.state
        if abs(bright - Double(st.bright)) > 2 { bright = Double(st.bright) }
        if abs(ct - Double(st.ct)) > 50 { ct = Double(st.ct) }
        if abs(bgBright - Double(st.bgBright)) > 2 { bgBright = Double(st.bgBright) }
        bgColor = Self.color(fromRGB: st.bgRGB)
    }

    private static func color(fromRGB rgb: Int) -> Color {
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    private static func rgbInt(from color: Color) -> Int {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return 0 }
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}
