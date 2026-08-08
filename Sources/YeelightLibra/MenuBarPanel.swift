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

    @State private var bright: Double = 10
    @State private var ct: Double = 3200
    @State private var bgBright: Double = 50
    @State private var bgColor: Color = Color(red: 0.8, green: 0.4, blue: 0.5)
    @State private var ipText = YeelightClient.defaultHost
    @State private var debounce: DispatchWorkItem?
    @State private var cronOption = 0
    @State private var segLeft: Color = .orange
    @State private var segRight: Color = .blue
    @AppStorage("chromaUDPEnabled") private var chromaEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            sectionTitle("主灯")
            Toggle(isOn: powerBinding(\.power)) { Text("电源") }
                .toggleStyle(.switch)
            sliderRow("亮度", value: $bright, range: 1...100) { value in
                Task { try? await client.setBright(Int(value)) }
            }
            sliderRow("色温", value: $ct, range: 2700...6500) { value in
                Task { try? await client.setCT(Int(value)) }
            }

            Divider()

            sectionTitle("背灯")
            Toggle(isOn: powerBinding(\.bgPower)) { Text("电源") }
                .toggleStyle(.switch)
            sliderRow("亮度", value: $bgBright, range: 1...100) { value in
                Task { try? await client.setBGBright(Int(value)) }
            }
            HStack {
                ColorPicker("颜色", selection: $bgColor, supportsOpacity: false)
                    .onChange(of: bgColor) { _, newColor in
                        let rgb = Self.rgbInt(from: newColor)
                        guard rgb != client.state.bgRGB else { return }
                        debounced { sendBGColor(rgb) }
                    }
                Spacer()
                Button("恢复") {
                    debounced { sendBGColor(LightState().bgRGB) }
                }
                .controlSize(.small)
            }

            Divider()

            sectionTitle("定时与流光")
            Picker("定时关灯", selection: $cronOption) {
                Text("取消").tag(0)
                Text("30 分钟").tag(30)
                Text("1 小时").tag(60)
                Text("2 小时").tag(120)
            }
            .disabled(!client.state.power)
            .onChange(of: cronOption) { _, newValue in
                guard client.state.power else { cronOption = 0; return }
                if newValue == 0 {
                    Task { try? await client.cancelCronOff() }
                } else {
                    Task { try? await client.setCronOff(afterMinutes: newValue) }
                }
            }
            HStack {
                Text("背光流光").frame(width: 66, alignment: .leading)
                Button("呼吸") { startFlow(.breath) }
                Button("彩虹") { startFlow(.rainbow) }
                Button("极光") { startFlow(.aurora) }
                Button("停止") { Task { try? await client.stopBGColorFlow() } }
                Spacer()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Divider()

            sectionTitle("分段背光（实验性）")
            HStack {
                ColorPicker("左", selection: $segLeft, supportsOpacity: false)
                    .onChange(of: segLeft) { _, c in
                        debounced { sendSegment(0, 0, c) }
                    }
                ColorPicker("右", selection: $segRight, supportsOpacity: false)
                    .onChange(of: segRight) { _, c in
                        debounced { sendSegment(1, 1, c) }
                    }
                Spacer()
                Button("整条") {
                    let c = segLeft
                    debounced { sendSegment(0, 255, c) }
                }
                .controlSize(.small)
            }

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
                if client.state.power, let minutes = try? await client.getCronOffDelayMinutes() {
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
                return "1200, 1, 16711680, 60; 1200, 1, 16711680, 5"
            case .rainbow:
                return "500, 3, 0, 100; 500, 3, 60, 100; 500, 3, 120, 100; 500, 3, 180, 100; 500, 3, 240, 100; 500, 3, 300, 100"
            case .aurora:
                return "800, 1, 65280, 40; 800, 1, 65535, 60; 800, 1, 16711935, 50; 800, 1, 16711680, 40"
            }
        }
    }

    private func startFlow(_ preset: FlowPreset) {
        let expression = preset.expression
        Task { try? await client.startBGColorFlow(expression) }
    }

    private func sendBGColor(_ rgb: Int) {
        if chromaEnabled && client.chromaConnected {
            client.chroma.bgSetRGB(rgb)
        } else {
            Task { try? await client.setBGRGB(rgb) }
        }
    }

    private func sendSegment(_ start: Int, _ end: Int, _ color: Color) {
        let rgb = Self.rgbInt(from: color)
        Task { try? await client.setSegmentRGB(start: start, end: end, rgb: rgb) }
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
                    Task { try? await client.refresh() }
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
        HStack {
            Text("主灯 \(client.state.mainStatusText) · 背灯 \(client.state.bgStatusText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
    }

    // MARK: - Helpers

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
        send: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Text(label).frame(width: 34, alignment: .leading)
            NativeSlider(value: value, range: range) { newValue in
                debounced { send(newValue) }
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
                if keyPath == \LightState.power {
                    Task { try? await client.setPower(on) }
                } else {
                    if chromaEnabled && client.chromaConnected {
                        client.chroma.bgSetPower(on)
                    } else {
                        Task { try? await client.setBGPower(on) }
                    }
                }
            }
        )
    }

    private func debounced(_ action: @escaping () -> Void) {
        debounce?.cancel()
        let work = DispatchWorkItem {
            Task { action() }
        }
        debounce = work
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
