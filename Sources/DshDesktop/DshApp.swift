import SwiftUI
import AppKit

@main
struct DshApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// CLI-parsed launch configuration. Read once at App init.
    private static let launchConfig = LaunchConfig.current()

    /// Resolved dsh location, populated during init. `nil` in `--no-spawn` mode
    /// (we don't manage dsh) or if init() bailed out before getting here.
    private static var dshLocation: DshLocator.Location?

    init() {
        Log.app.info("DshDesktop starting; port=\(Self.launchConfig.resolvedPort) noSpawn=\(Self.launchConfig.noSpawn) debug=\(Self.launchConfig.debug)")
        if Self.launchConfig.help {
            print(LaunchConfig.helpText)
            exit(0)
        }
        Self.enforceSingleInstance()
        if !Self.launchConfig.noSpawn {
            // Locate dsh before showing any UI so a missing install gets a
            // friendly alert instead of a cryptic Process.run() error.
            // --dsh-path skips the shell-based lookup entirely.
            do {
                if let path = Self.launchConfig.dshPath {
                    Self.dshLocation = DshLocator.Location(
                        executablePath: path,
                        arguments: ["dsh", "--profile", "web"]
                    )
                } else {
                    Self.dshLocation = try DshLocator.locate()
                }
            } catch {
                Self.showAlertAndExit(title: "dsh not found", message: error.localizedDescription)
            }
        }
    }

    /// Detect an already-running instance of DshDesktop via NSRunningApplication.
    /// If found, focus it and exit; otherwise, we're the canonical instance.
    /// Skipped under `--no-spawn` only when the user explicitly opts in via
    /// `--allow-multiple` (not yet implemented); for now, single instance is
    /// always enforced.
    private static func enforceSingleInstance() {
        let bundleID = Bundle.main.bundleIdentifier ?? "ai.deepseek.dsh.desktop"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).filter { $0.processIdentifier != myPID }
        guard let existing = others.first else { return }
        Log.app.notice("Another instance already running (pid=\(existing.processIdentifier)); focusing it and quitting")
        existing.activate(options: [.activateAllWindows])
        // Give the existing instance a moment to come forward, then exit.
        Thread.sleep(forTimeInterval: 0.3)
        exit(0)
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
                port: cfg.resolvedPort,
                ownsChild: false
            )
        }
        // Use the resolved path from init(); fall back to /bin/false (will fail
        // safely at start) only if init() somehow didn't set it.
        let location = DshApp.dshLocation
        let executable = location.map { URL(fileURLWithPath: $0.executablePath) }
            ?? URL(fileURLWithPath: "/bin/false")
        let arguments = location?.arguments ?? ["dsh"]
        return DshProcess(executable: executable, arguments: arguments, port: cfg.resolvedPort)
    }()

    @StateObject private var prefs = Preferences.shared

    @StateObject private var idleWatcher: AgentIdleWatcher = {
        let prefs = Preferences.shared
        return AgentIdleWatcher(
            evaluator: { false },
            isNotificationsEnabled: { prefs.notificationsEnabled }
        )
    }()

    var body: some Scene {
        Window("DshDesktop", id: "main") {
            ContentView(process: process, prefs: prefs, idleWatcher: idleWatcher)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    appDelegate.process = process
                    appDelegate.idleWatcher = idleWatcher
                    DSHAppProxy.process = process
                    // Health monitor: detect when dsh's port stops responding
                    // (i.e. dsh died) and surface the FailedOverlay.
                    DshHealthMonitor.shared.attach(to: process)
                    DshHealthMonitor.shared.start()
                }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Hide all default menus — we only ship our own (App / dsh /
            // Quick Links). macOS otherwise shows File / Edit / View /
            // Window / Help which add nothing for a WKWebView wrapper.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .printItem) {}
            CommandGroup(replacing: .pasteboard) {}
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .textEditing) {}
            CommandGroup(replacing: .help) {}
            // Window menu group (Minimize / Zoom / Bring All to Front /
            // window list). Single-window wrapper has no use for these.
            CommandGroup(replacing: .windowList) {}
            CommandGroup(replacing: .windowSize) {}
            CommandGroup(replacing: .windowArrangement) {}
            // View menu group (Toggle Toolbar / Toggle Sidebar / etc.).
            // WKWebView wrapper doesn't have a SwiftUI toolbar or sidebar,
            // so these items would just be inert clutter.
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(replacing: .sidebar) {}

            // App menu (About + Quit + Settings)
            CommandGroup(replacing: .appInfo) {
                Button("About DshDesktop") {
                    let body = NSMutableAttributedString()
                    body.append(NSAttributedString(
                        string: "\nA native macOS wrapper for dsh.\n\n",
                        attributes: [.font: NSFont.systemFont(ofSize: 11)]
                    ))
                    body.append(NSAttributedString(
                        string: "\nReleased under the MIT License.\n",
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

            // Settings… — Cmd+, standard macOS shortcut. Opens the
            // liquid-glass Settings window backed by SettingsWindowController.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    SettingsWindowController.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // Wrapper operations menu (Chinese label "控制"). Per user request —
            // English users will see the literal string "控制" until a
            // zh-Hans/English split becomes a thing; the wrapper's
            // primary audience is the zh-Hans-locale user.
            CommandMenu("控制") {
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

                Button("Save Diagnostic Report…") {
                    appDelegate.saveDiagnosticReport()
                }
            }

            // Quick Links menu — external references the user wants one click
            // away. We NSWorkspace.shared.open (not the dsh webview) so
            // these always go to the system browser, never into the
            // wrapper window.
            CommandMenu("Quick Links") {
                Button("dsh 资源导航 (dshfind)") {
                    if let url = URL(string: "https://dshfind.com/zh") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Awesome dsh Plugins") {
                    if let url = URL(string: "https://awesome-dsh-plugin.com/zh/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("dsh GitHub Repo") {
                    if let url = URL(string: "https://github.com/deepseek-ai/deepseek-harness") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        // Settings scene — opens via Cmd+, (standard macOS shortcut).
        // Replaced by a custom NSWindowController-based window for
        // liquid glass styling on macOS 26 (NavigationSplitView sidebar +
        // .fullSizeContentView). See SettingsWindowController.swift.
        //
        // Cmd+, wiring lives in the menu block above (the "Settings…"
        // item calls SettingsWindowController.show()).
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    /// Set by `DshApp.body.onAppear`. Strong refs so deinit doesn't drop them
    /// while a window-delegate callback still references them.
    var process: DshProcess?
    var idleWatcher: AgentIdleWatcher?

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
            // SwiftUI's `CommandGroup(replacing: .help / .windowList / ...)`
            // empties the contents but does NOT remove the menu itself
            // (AppKit auto-adds Help + Window menus based on a windowed
            // app). Remove them from the live NSApp.mainMenu after SwiftUI
            // has finished building the menu bar.
            Self.pruneAutoMenus()
        }
    }

    /// Remove the menus that AppKit auto-adds to every windowed macOS app
    /// but the wrapper doesn't want to expose. SwiftUI's
    /// `CommandGroup(replacing: ...)` only empties their contents, so
    /// we walk `NSApp.mainMenu` and delete the unwanted top-level items
    /// by title.
    ///
    /// Diagnostic logging is included so future "menu still there" bugs
    /// can be debugged from `log show --predicate 'subsystem == "ai.deepseek.dsh.desktop"'`.
    @MainActor
    static func pruneAutoMenus() {
        guard let mainMenu = NSApp.mainMenu else {
            Log.app.debug("pruneAutoMenus: NSApp.mainMenu is nil — nothing to do")
            return
        }
        // Log every menu title BEFORE pruning. privacy: .public opts out of
        // os.log's automatic redaction of dynamic string interpolations.
        // (Each interpolation gets its own privacy spec; the join happens
        //  outside os.log so we can't re-apply privacy on the result.)
        let beforeTitles = mainMenu.items.map { item -> String in
            if let sub = item.submenu { return "\(item.title) [sub=\(sub.title)]" }
            return item.title
        }
        // Joined string is itself a String, so we wrap it back into
        // a single privacy: .public interpolation here. The interpolations
        // inside `map` produce plain Strings because closure return type
        // is String, not OSLogMessage — we apply privacy only on the
        // final log line.
        let joinedBefore = beforeTitles.joined(separator: ", ")
        Log.app.debug("pruneAutoMenus: BEFORE — \(joinedBefore, privacy: .public)")

        let dropTitles: Set<String> = [
            "Help", "Window", "View", "Format",
            "帮助", "窗口", "显示", "视图", "格式",
        ]
        var keepGoing = true
        while keepGoing {
            keepGoing = false
            for (index, item) in mainMenu.items.enumerated() {
                if let title = item.submenu?.title, dropTitles.contains(title) {
                    Log.app.debug("pruneAutoMenus: removing submenu \(title, privacy: .public)")
                    mainMenu.removeItem(at: index)
                    keepGoing = true
                    break
                }
                if dropTitles.contains(item.title) {
                    Log.app.debug("pruneAutoMenus: removing top-level \(item.title, privacy: .public)")
                    mainMenu.removeItem(at: index)
                    keepGoing = true
                    break
                }
            }
        }
        // Log AFTER for confirmation.
        let afterTitles = mainMenu.items.map { ($0.submenu?.title ?? $0.title) as String }
        let joinedAfter = afterTitles.joined(separator: ", ")
        Log.app.debug("pruneAutoMenus: AFTER — \(joinedAfter, privacy: .public)")
    }

    @MainActor
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
        let proc = process
        Task { @MainActor in
            await proc?.stop()
            NSApp.terminate(nil)
        }
    }

    /// Triggered from the dsh ▸ Save Diagnostic Report… menu item.
    /// Writes a plain-text report to a user-chosen location.
    @MainActor
    func saveDiagnosticReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "DshDesktop-Diagnostic-\(timestampString()).txt"
        panel.title = "Save Diagnostic Report"
        panel.message = "Save a snapshot of the wrapper's state for debugging."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report = Diagnostics.generateReport()
            try report.write(to: url, atomically: true, encoding: .utf8)
            Log.app.info("Diagnostic report written to \(url.path, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Diagnostic report saved"
            alert.informativeText = url.path
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            Log.errors.error("Failed to write diagnostic report: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Failed to save diagnostic report"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func timestampString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return fmt.string(from: Date())
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
        // Idle-watcher polling keeps running so the completion
        // notification still fires while the window is closed.
    }

    func windowDidBecomeKey(_ notification: Notification) {}

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension Notification.Name {
    static let dshReload = Notification.Name("dshReload")
}