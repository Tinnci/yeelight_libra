import AppKit
import SwiftUI

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var client: YeelightClient!
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let dockActions = DockActions()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let host = UserDefaults.standard.string(forKey: "deviceIP") ?? YeelightClient.defaultHost
        client = YeelightClient(host: host)
        dockActions.client = client
        dockActions.showPanel = { [weak self] in self?.showPanel() }
        client.start()
        setupStatusItem()
    }

    // MARK: - Menu bar item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "lamp.desk.fill",
                                   accessibilityDescription: "Yeelight Libra")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }
        statusItem = item
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
            let hosting = NSHostingController(rootView: MenuBarPanel(client: client))
            hosting.sizingOptions = []
            hosting.view.frame = NSRect(x: 0, y: 0, width: 360, height: 680)
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
        client?.disconnect()
    }
}
