import AppKit
import SwiftUI
import Combine

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var client: YeelightClient!
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let dockActions = DockActions()
    private var statusCancellable: AnyCancellable?
    private var autoController: AutoModeController!

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let host = UserDefaults.standard.string(forKey: "deviceIP") ?? YeelightClient.defaultHost
        client = YeelightClient(host: host)
        autoController = AutoModeController(client: client)
        dockActions.client = client
        dockActions.showPanel = { [weak self] in self?.showPanel() }
        client.start()
        setupStatusItem()
    }

    // MARK: - Menu bar item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "lamp.desk.fill",
                                accessibilityDescription: "Yeelight Libra")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }
        statusItem = item
        // Immediate visual feedback: tint the icon by TCP connection state.
        updateStatusIcon(connected: client.isConnected)
        statusCancellable = client.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.updateStatusIcon(connected: connected)
            }
    }

    /// Green icon while connected, red while disconnected, with a tooltip
    /// summarizing the state.
    private func updateStatusIcon(connected: Bool) {
        guard let button = statusItem?.button else { return }
        button.contentTintColor = connected ? .systemGreen : .systemRed
        button.toolTip = connected ? "已连接 \(client.host)" : "未连接，将自动重连"
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let button = statusItem?.button else { return }
        if popover == nil {
            let pop = NSPopover()
            pop.behavior = .transient
            let hosting = NSHostingController(rootView: MenuBarPanel(client: client, autoController: autoController))
            hosting.sizingOptions = []
            hosting.view.frame = NSRect(x: 0, y: 0, width: 360, height: 760)
            pop.contentViewController = hosting
            pop.contentSize = hosting.view.frame.size
            popover = pop
        }
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Dock menu

    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockActions.menu()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        autoController?.stop()
        client?.disconnect()
    }
}
