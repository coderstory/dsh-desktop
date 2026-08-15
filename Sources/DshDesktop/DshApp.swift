import SwiftUI
import AppKit

@main
struct DshApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var process: DshProcess = {
        let executable = URL(fileURLWithPath: "/usr/bin/env")
        return DshProcess(executable: executable, arguments: ["dsh", "--profile", "web"], port: 3080)
    }()

    var body: some Scene {
        Window("dsh", id: "main") {
            ContentView(process: process)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear { appDelegate.process = process }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("File") {
                Button("Open in Browser") {
                    if let url = URL(string: "http://127.0.0.1:3080/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("b", modifiers: [.command])
                Button("Reload") {
                    NotificationCenter.default.post(name: .dshReload, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // Keep strong ref so we can stop the process on quit.
    var process: DshProcess?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hook all windows' delegate to detect close.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.delegate = self
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Last window closing → quit the app cleanly.
        Task { [weak self] in
            guard let self else { return }
            await self.process?.stop()
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension Notification.Name {
    static let dshReload = Notification.Name("dshReload")
}
