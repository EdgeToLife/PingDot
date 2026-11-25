import AppKit

@main
enum PingDotApp {
    @MainActor
    static func main() {
        // Консольная проверка пинга без интерфейса.
        if ProcessInfo.processInfo.arguments.contains("--check") {
            Pinger.selfTest()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // без иконки в Dock
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(monitor: Monitor())
    }
}
