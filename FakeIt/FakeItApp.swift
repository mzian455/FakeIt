import AppKit
import SwiftUI

@main
struct FakeItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .background(FakeItTheme.background)
        }
        .defaultSize(width: 1240, height: 800)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                window.title = "FakeIt — Location Spoofer"
                window.backgroundColor = NSColor(red: 0.051, green: 0.051, blue: 0.051, alpha: 1)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        for window in NSApplication.shared.windows where window.title != "FakeIt — Location Spoofer" {
            window.title = "FakeIt — Location Spoofer"
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DeviceService.stopLocationHoldProcess()
        DeviceService.stopTunneldIfStartedByFakeItSync()
    }
}
