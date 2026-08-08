import SwiftUI
import YeelightLibraCore

@main
struct YeelightLibraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
