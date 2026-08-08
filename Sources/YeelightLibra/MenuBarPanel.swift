import SwiftUI
import AppKit

/// SwiftUI `Slider` triggers an infinite layout loop when more than one is
/// placed inside a single `NSPopover` on macOS. Wrapping the AppKit-native
/// `NSSlider` avoids that bug entirely.
struct NativeSlider: NSViewRepresentable {
    let value: Binding<Double>
    let range: ClosedRange<Double>

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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                        debounced {
                            Task { try? await client.setBGRGB(rgb) }
                        }
                    }
                Spacer()
                Button("恢复") {
                    debounced {
                        Task { try? await client.setBGRGB(LightState().bgRGB) }
                    }
                }
                .controlSize(.small)
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            ipText = client.host
            syncFromState()
        }
        .onChange(of: client.state) { _, _ in
            syncFromState()
        }
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

    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        send: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Text(label).frame(width: 34, alignment: .leading)
            NativeSlider(value: value, range: range)
                .onChange(of: value.wrappedValue) { _, newValue in
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
                Task {
                    if keyPath == \LightState.power {
                        try? await client.setPower(on)
                    } else {
                        try? await client.setBGPower(on)
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
