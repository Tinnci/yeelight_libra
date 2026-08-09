import Foundation
import Combine

/// The shared manual-control entry point for the popover and Dock menu.
/// It owns automation handoff, Chroma/TCP selection, and operation errors.
@MainActor
final class LightControlUseCases: ObservableObject {
    let client: YeelightClient
    let autoController: AutoModeController
    @Published private(set) var lastError: String?

    init(client: YeelightClient, autoController: AutoModeController) {
        self.client = client
        self.autoController = autoController
    }

    func setMainPower(_ on: Bool) { autoController.userTookMainControl(); perform("主灯电源") { try await self.client.setPower(on) } }
    func setMainBrightness(_ value: Int) { autoController.userTookMainControl(); perform("主灯亮度") { try await self.client.setBright(value) } }
    func setMainCT(_ value: Int) { autoController.userTookMainControl(); perform("主灯色温") { try await self.client.setCT(value) } }

    func setBacklightPower(_ on: Bool) {
        autoController.userTookBacklightControl()
        if client.chroma.isRunning && client.chromaConnected {
            client.chroma.bgSetPower(on)
            client.projectBacklightPower(on)
        } else {
            perform("背灯电源") { try await self.client.setBGPower(on) }
        }
    }

    func setBacklightBrightness(_ value: Int) {
        autoController.userTookBacklightControl()
        perform("背灯亮度") { try await self.client.setBGBright(value) }
    }

    func setBacklightColor(_ rgb: Int) {
        autoController.userTookBacklightControl()
        if client.chroma.isRunning && client.chromaConnected {
            client.chroma.bgSetRGB(rgb)
        } else {
            perform("背灯颜色") { try await self.client.setBGRGB(rgb) }
        }
    }

    func applyScene(_ scene: ScenePreset) {
        autoController.userTookMainControl()
        autoController.userTookBacklightControl()
        perform("应用场景") { try await self.client.applyScene(scene) }
    }

    func startBacklightFlow(_ expression: String) {
        autoController.userTookBacklightControl()
        perform("启动流光") { try await self.client.startBGColorFlow(expression) }
    }

    func stopBacklightFlow() {
        autoController.userTookBacklightControl()
        perform("停止流光") { try await self.client.stopBGColorFlow() }
    }

    func setSegment(start: Int, end: Int, rgb: Int) {
        autoController.userTookBacklightControl()
        perform("分段背光") { try await self.client.setSegmentRGB(start: start, end: end, rgb: rgb) }
    }

    func refresh() { perform("刷新状态") { try await self.client.refresh() } }
    func setCronOff(afterMinutes minutes: Int) { perform("设置定时关灯") { try await self.client.setCronOff(afterMinutes: minutes) } }
    func cancelCronOff() { perform("取消定时关灯") { try await self.client.cancelCronOff() } }

    private func perform(_ label: String, _ operation: @escaping () async throws -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await operation()
                self.lastError = nil
            } catch {
                self.lastError = "\(label)失败：\(error.localizedDescription)"
                Logger.log("\(label) failed: \(error)")
            }
        }
    }
}
