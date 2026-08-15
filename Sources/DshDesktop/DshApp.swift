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
            // Hide all default menus
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .printItem) {}
            CommandGroup(replacing: .pasteboard) {}
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .textEditing) {}
            CommandGroup(replacing: .help) {}

            // App menu (About + Quit)
            CommandGroup(replacing: .appInfo) {
                Button("About DshDesktop") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit DshDesktop") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }

            // dsh operations menu
            CommandMenu("dsh") {
                Button("Restart dsh") {
                    Task { await process.restart() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Refresh Page") {
                    NotificationCenter.default.post(name: .dshReload, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                Button("Update dsh…") {
                    appDelegate.runDshUpdate()
                }
            }

            // Quick Links menu
            CommandMenu("Quick Links") {
                Button("GitHub Repo") {
                    if let url = URL(string: "https://github.com/deepseek-ai/deepseek-harness") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // Keep strong ref so we can stop the process on quit.
    var process: DshProcess?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        // Hook all windows' delegate to detect close.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.delegate = self
            }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Custom template image (auto-loaded from app's Resources directory)
            if let image = Bundle.main.image(forResource: "MenuBarIconTemplate") {
                image.isTemplate = true
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "rectangle.connected.to.line.below", accessibilityDescription: "dsh")
            }
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show dsh", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func showWindow() {
        for window in NSApp.windows where !window.isVisible {
            // No-op; clicking the menu item just unhides existing window below.
        }
        NSApp.windows.forEach { $0.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        Task { [weak self] in
            await self?.process?.stop()
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    /// Triggered from the dsh ▸ Update dsh… menu item.
    func runDshUpdate() {
        let alert = NSAlert()
        alert.messageText = "Update dsh"
        alert.informativeText = "Run `npm update -g @deepseek-ai/dsh`? A restart will be required afterward."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            let result = await ShellRunner.run(
                "/usr/bin/env",
                ["npm", "update", "-g", "@deepseek-ai/dsh"]
            )
            await MainActor.run {
                let doneAlert = NSAlert()
                doneAlert.messageText = result.success ? "Update successful" : "Update failed"
                doneAlert.informativeText = "Exit \(result.exitCode)\n\n\(result.output)"
                doneAlert.addButton(withTitle: "OK")
                doneAlert.runModal()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Window hidden (LSUIElement style). App stays alive.
        // User reopens via menu bar icon's "Show dsh" item.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension Notification.Name {
    static let dshReload = Notification.Name("dshReload")
}
