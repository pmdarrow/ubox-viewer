import SwiftUI
import Darwin

@main
struct UBoxViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // POSIX signal handlers so kill/pkill (SIGTERM/SIGINT) also tear down
        // the relay session. AppKit's terminate hooks only fire for graceful
        // exits (Cmd+Q, menu Quit). Without these, signals leave dangling
        // sessions on the camera/relay that wedge subsequent connections.
        let cleanup: @convention(c) (Int32) -> Void = { _ in
            StreamManager.shared.disconnect()
            // Re-raise default handler so the process actually exits.
            _exit(0)
        }
        signal(SIGTERM, cleanup)
        signal(SIGINT, cleanup)
        signal(SIGHUP, cleanup)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 640, minHeight: 480)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    StreamManager.shared.disconnect()
                }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        StreamManager.shared.disconnect()
    }

    // Treat closing the last window as quitting so the relay session is
    // properly torn down. Without this, killing the window leaves dangling
    // sessions on the camera/relay that wedge subsequent connections.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // Block termination briefly so the disconnect's logout packets can be
    // flushed by the kernel before the process exits. UDP is fire-and-forget;
    // without a short window, the logouts never leave the host.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DispatchQueue.global(qos: .userInitiated).async {
            StreamManager.shared.disconnect()
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}
