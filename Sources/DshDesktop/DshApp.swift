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
            do {
                Self.dshLocation = try DshLocator.locate()
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
            pollInterval: prefs.pollingIntervalSeconds,
            evaluator: { false },
            isNotificationsEnabled: { prefs.notificationsEnabled }
        )
    }()

    var body: some Scene {
        Window("dsh", id: "main") {
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
                // Hot-reload: when user changes polling interval in Settings,
                // push the new value into the running watcher.
                .onChange(of: prefs.pollingIntervalSeconds) { _, newValue in
                    idleWatcher.pollInterval = newValue
                }
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

                Button("Save Diagnostic Report…") {
                    appDelegate.saveDiagnosticReport()
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

        // Settings scene — opens via Cmd+, (standard macOS shortcut).
        Settings {
            PreferencesView(prefs: prefs)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    /// Set by `DshApp.body.onAppear`. Strong refs so deinit doesn't drop them
    /// while a window-delegate callback still references them.
    var process: DshProcess?
    var idleWatcher: AgentIdleWatcher?

    private var statusItem: NSStatusItem?
    private var performanceMenuItem: NSMenuItem?

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
        if Preferences.shared.enablePerformanceMonitoring {
            menu.addItem(.separator())
            let perfItem = NSMenuItem(
                title: "Performance: \(self.performanceSummary())",
                action: #selector(showPerformance),
                keyEquivalent: ""
            )
            perfItem.target = self
            menu.addItem(perfItem)
            performanceMenuItem = perfItem
            // Live-update title on every sample. PerformanceMonitor is
            // @MainActor; this assignment needs MainActor context.
            let menuItemRef = perfItem
            let summaryFn: @MainActor () -> String = { [weak self] in
                self?.performanceSummary() ?? "—"
            }
            Task { @MainActor in
                PerformanceMonitor.shared.onUpdate = {
                    Task { @MainActor in
                        menuItemRef.title = "Performance: \(summaryFn())"
                    }
                }
            }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit"), action: #selector(quitApp), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @MainActor
    private func performanceSummary() -> String {
        guard let stats = PerformanceMonitor.shared.lastStats else { return "no data yet" }
        let mem = stats.memoryMB.map { "\($0)MB" } ?? "—"
        return "\(stats.longTaskCount) long tasks · \(mem)"
    }

    @MainActor
    @objc private func showPerformance() {
        guard let stats = PerformanceMonitor.shared.lastStats else {
            let alert = NSAlert()
            alert.messageText = "Performance"
            alert.informativeText = "No data sampled yet. PerformanceMonitor samples every 10 seconds — wait a moment, then check again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let mem = stats.memoryMB.map { "\($0) MB" } ?? "—"
        let spike = stats.lastSpikeAt.map { "last long task at +\(Int($0 / 1000))s" } ?? "no long tasks"
        let pluginList = stats.plugins.isEmpty ? "(none found in DOM)" : stats.plugins.joined(separator: "\n  • ")
        let alert = NSAlert()
        alert.messageText = "dsh Performance"
        alert.informativeText = """
        Long tasks (>100ms): \(stats.longTaskCount)
        Cumulative duration: \(stats.longTaskTotalMs) ms
        JS heap: \(mem)
        Last spike: \(spike)

        Active plugins (\(stats.pluginCount)):
          • \(pluginList)

        (WebKit's PerformanceLongTaskTiming doesn't expose the
        `attribution` field, so we can't pinpoint the specific plugin
        responsible — cross-reference the active list with the spike
        timing to identify likely culprits.)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
        if Preferences.shared.pausePollingWhenHidden {
            idleWatcher?.pause()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Resume the idle-watcher polling when the window comes back.
        if Preferences.shared.pausePollingWhenHidden {
            idleWatcher?.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension Notification.Name {
    static let dshReload = Notification.Name("dshReload")
}