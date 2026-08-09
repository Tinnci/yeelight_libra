import AppKit

/// Builds the menu shown when right-clicking / long-pressing the Dock icon.
@MainActor
final class DockActions: NSObject {
    var client: YeelightClient?
    var autoController: AutoModeController?
    var showPanel: (() -> Void)?

    func menu() -> NSMenu {
        let menu = NSMenu()
        let state = client?.state

        let open = NSMenuItem(title: "打开控制面板", action: #selector(openPanel(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let mainPower = NSMenuItem(
            title: (state?.mainPower ?? false) ? "关闭主灯" : "打开主灯",
            action: #selector(toggleMain(_:)),
            keyEquivalent: ""
        )
        mainPower.target = self
        menu.addItem(mainPower)

        let mainBright = NSMenuItem(title: "主灯亮度", action: nil, keyEquivalent: "")
        mainBright.submenu = brightnessSubmenu(selector: #selector(setMainBright(_:)))
        menu.addItem(mainBright)

        let bgPower = NSMenuItem(
            title: (state?.bgPower ?? false) ? "关闭背灯" : "打开背灯",
            action: #selector(toggleBG(_:)),
            keyEquivalent: ""
        )
        bgPower.target = self
        menu.addItem(bgPower)

        let bgBright = NSMenuItem(title: "背灯亮度", action: nil, keyEquivalent: "")
        bgBright.submenu = brightnessSubmenu(selector: #selector(setBGBright(_:)))
        menu.addItem(bgBright)

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "刷新状态", action: #selector(refresh(_:)), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let quit = NSMenuItem(title: "退出 Yeelight Libra", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func brightnessSubmenu(selector: Selector) -> NSMenu {
        let submenu = NSMenu()
        for value in [25, 50, 75, 100] {
            let item = NSMenuItem(title: "\(value)%", action: selector, keyEquivalent: "")
            item.tag = value
            item.target = self
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func openPanel(_ sender: Any?) {
        showPanel?()
    }

    @objc private func toggleMain(_ sender: Any?) {
        guard let client else { return }
        autoController?.userTookMainControl()
        Task { try? await client.setPower(!client.state.mainPower) }
    }

    @objc private func toggleBG(_ sender: Any?) {
        guard let client else { return }
        autoController?.userTookBacklightControl()
        Task { try? await client.setBGPower(!client.state.bgPower) }
    }

    @objc private func setMainBright(_ sender: NSMenuItem) {
        guard let client else { return }
        autoController?.userTookMainControl()
        Task { try? await client.setBright(sender.tag) }
    }

    @objc private func setBGBright(_ sender: NSMenuItem) {
        guard let client else { return }
        autoController?.userTookBacklightControl()
        Task { try? await client.setBGBright(sender.tag) }
    }

    @objc private func refresh(_ sender: Any?) {
        guard let client else { return }
        Task { try? await client.refresh() }
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
