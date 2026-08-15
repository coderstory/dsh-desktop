import SwiftUI
import AppKit

@main
struct DshApp: App {

    @StateObject private var process: DshProcess = {
        // Find `dsh` in PATH; fall back to bare name and let Process resolve via env.
        let executable = URL(fileURLWithPath: "/usr/bin/env")
        return DshProcess(executable: executable, arguments: ["dsh", "--profile", "web"], port: 3080)
    }()

    var body: some Scene {
        Window("dsh", id: "main") {
            ContentView(process: process)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Replace default "New" with useful commands.
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

extension Notification.Name {
    static let dshReload = Notification.Name("dshReload")
}
