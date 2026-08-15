import SwiftUI
import AppKit

@main
struct DshApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// CLI-parsed launch configuration. Read once at App init.
    private static let launchConfig = LaunchConfig.current

    /// Resolved dsh location, populated during init. `nil` in `--no-spawn` mode
    /// (we don't manage dsh) or if init() bailed out before getting here.
    private static var dshLocation: DshLocator.Location?

    init() {
        Log.app.info("DshDesktop starting; port=\(Self.launchConfig.port) noSpawn=\(Self.launchConfig.noSpawn) debug=\(Self.launchConfig.debug)")
        if Self.launchConfig.help {
            print(LaunchConfig.helpText)
            exit(0)
        }
        if !Self.launchConfig.noSpawn {
            // Locate dsh before showing any UI so a missing install gets a
            // friendly alert instead of a cryptic Process.run() error.
            do {
                Self.dshLocation = try DshLocator.locate()
            } catch {
                Self.showAlertAndExit(title: "dsh not found", message: error.localizedDescription)
            }
        }
    }

    private static func showAlertAndExit(title: String, message: String) -> Never {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(1)
    }

    @StateObject private var process: DshProcess = {
        let cfg = DshApp.launchConfig
        if cfg.noSpawn {
            // External dsh: the wrapper connects but doesn't manage lifecycle.
            return DshProcess(
                executable: URL(fileURLWithPath: "/bin/true"),
                arguments: [],
                port: cfg.port,
                ownsChild: false
            )
        }
        // Use the resolved path from init(); fall back to /bin/false (will fail
        // safely at start) only if init() somehow didn't set it.
        let location = DshApp.dshLocation
        let executable = location.map { URL(fileURLWithPath: $0.executablePath) }
            ?? URL(fileURLWithPath: "/bin/false")
        let arguments = location?.arguments ?? ["dsh"]
        return DshProcess(executable: executable, arguments: arguments, port: cfg.port)
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
                    let body = NSMutableAttributedString()
                    body.append(NSAttributedString(
                        string: "\nA native macOS wrapper for dsh.\n\n",
                        attributes: [.font: NSFont.systemFont(ofSize: 11)]
                    ))
                    body.append(NSAttributedString(
                        string: "View on GitHub →",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 11),
                            .link: URL(string: "https://github.com/deepseek-ai/deepseek-harness")!,
                            .foregroundColor: NSColor.controlAccentColor
                        ]
                    ))
                    body.append(NSAttributedString(
                        string: "\n\nReleased under the MIT License.\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 10),
                            .foregroundColor: NSColor.secondaryLabelColor
                        ]
                    ))
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: body])
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

                Toggle("Launch at Login", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled() },
                    set: { _ in LaunchAtLogin.toggle() }
                ))

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

    private static let mainWindowAutosaveName = "DshDesktop.MainWindow"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        // Hook all windows' delegate to detect close.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                // Restore + persist frame (position, size, display) across launches
                _ = window.setFrameAutosaveName(Self.mainWindowAutosaveName)
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
        menu.addItem(NSMenuItem(title: String(localized: "Show dsh"), action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit"), action: #selector(quitApp), keyEquivalent: "q"))
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
        Log.menu.info("Update dsh requested")
        let alert = NSAlert()
        alert.messageText = String(localized: "Update dsh")
        alert.informativeText = String(localized: "Run `npm update -g @deepseek-ai/dsh`? A restart will be required afterward.")
        alert.addButton(withTitle: String(localized: "Update"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            let result = await ShellRunner.run(
                "/usr/bin/env",
                ["npm", "update", "-g", "@deepseek-ai/dsh"]
            )
            await MainActor.run {
                Log.dsh.info("Update dsh: exit=\(result.exitCode) success=\(result.success)")
                let doneAlert = NSAlert()
                doneAlert.messageText = result.success
                    ? String(localized: "Update successful")
                    : String(localized: "Update failed")
                doneAlert.informativeText = String(
                    format: String(localized: "Exit %d\n\n%@"),
                    result.exitCode, result.output
                )
                doneAlert.addButton(withTitle: String(localized: "OK"))
                doneAlert.runModal()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        Log.ui.info("main window closed; app stays in menu bar")
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
