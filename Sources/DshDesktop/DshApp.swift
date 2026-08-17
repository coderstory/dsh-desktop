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
        // Detect dsh-desktop-bridge plugin status. We do this synchronously
        // here so the user sees an actionable alert *before* the window
        // opens if the plugin is missing / disabled / outdated — that way
        // the dialog blocks the first-launch confusion rather than letting
        // the wrapper silently fall back to its old (unreliable) DOM-probe
        // notification path. The window is suppressed with .alert until
        // the user dismisses, so the launch sequence stays predictable.
        //
        // Skip in --no-spawn mode: the bridge relies on a dsh process that
        // owns the plugin, and if there's no dsh there's nothing to bridge
        // to. Detection runs anyway (it's pure I/O), but the alert is
        // suppressed so it doesn't pop up in headless / CI runs.
        //
        // CRITICAL: do NOT call checkBridgePluginAndAlertIfNeeded() here —
        // NSAlert.runModal() in SwiftUI's early-startup window race freezes
        // the launch. Use the non-blocking variant which auto-installs
        // the missing-plugin patch and logs the verdict. The interactive
        // alert variant is reserved for the "Check Bridge Plugin…" menu
        // item which runs after the runloop is stable.
        Self.detectAndAutoInstallBridgePlugin()
        // Start the unix-domain socket server so the dsh-desktop-bridge
        // plugin has a target to connect to. Failure is non-fatal: the
        // wrapper keeps running and falls back to the (unreliable) DOM-probe
        // notification path. We capture the bridge on a static so the
        // AppDelegate can call stop() on it at applicationWillTerminate.
        if Self.launchConfig.noSpawn {
            Log.bridge.notice("DSHBridge: skipped in --no-spawn mode")
        } else {
            Self.startBridge()
        }
    }

    /// Start the DSHBridge server. Singleton-ish (one bridge per wrapper
    /// instance, since DshApp is a singleton by virtue of the single-
    /// instance guard in `enforceSingleInstance`). Held statically so the
    /// AppDelegate can reach it for clean shutdown.
    nonisolated(unsafe) static var sharedBridge: DSHBridge?

    private static func startBridge() {
        let bridge = DSHBridge(
            notifyHandler: { title, body in
                await Notifications.notify(title: title, body: body)
            },
            prefsHandler: { key in
                switch key {
                case "notifications.enabled": return Preferences.shared.notificationsEnabled
                default: return nil
                }
            },
            prefsSetHandler: { key, value in
                if key == "notifications.enabled", let b = value as? Bool {
                    Preferences.shared.notificationsEnabled = b
                }
            }
        )
        do {
            try bridge.start()
            sharedBridge = bridge
        } catch {
            // Non-fatal: the wrapper keeps running. The user will see
            // spammy notifications until they (a) install the plugin,
            // and we surface that path via checkBridgePluginAndAlertIfNeeded.
            Log.bridge.error("DSHBridge: failed to start — \(String(describing: error))")
            sharedBridge = nil
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

    /// Run DSHPluginDetector against the user's dsh profile and surface an
    /// NSAlert if the plugin needs user attention. Silent on success.
    ///
    /// Decision tree (see DSHPluginDetector.Status.State for the canonical
    /// definitions):
    ///
    ///   - .installedCurrent          → no alert, continue
    ///   - .notInstalled              → alert: "Install dsh-desktop-bridge"
    ///   - .installedOutdated(...)    → alert: "Update dsh-desktop-bridge"
    ///   - .disabled                  → alert: "Plugin disabled — re-enable"
    ///   - .brokenPath(...)           → alert: "Plugin path missing"
    ///
    /// Skipped under --no-spawn / --help (the help case already exits; the
    /// no-spawn case has no dsh to bridge to).
    private static func checkBridgePluginAndAlertIfNeeded() {
        // Interactive alert variant — only called from the "Check Bridge Plugin…"
        // menu item, after the runloop is stable. NSAlert.runModal() in
        // SwiftUI's early-startup window race freezes the launch sequence,
        // so the launch-time detection uses detectAndAutoInstallBridgePlugin()
        // (below) which never blocks the main thread.
        if Self.launchConfig.help || Self.launchConfig.noSpawn { return }

        let dshHome = ProcessInfo.processInfo.environment["DSH_HOME"]
            ?? NSHomeDirectory() + "/.dsh"
        let status = DSHPluginDetector.detect(dshHome: dshHome)

        Log.pluginDetector.notice("bridge plugin detection verdict: \(String(describing: status.state), privacy: .public)")

        switch status.state {
        case .installedCurrent:
            return // silent

        case .notInstalled:
            let alert = NSAlert()
            alert.messageText = "Plugin not installed: \(DSHPluginDetector.pluginID)"
            alert.informativeText = """
                DshDesktop needs the dsh-desktop-bridge plugin to forward agent
                completion events to native macOS notifications (the old DOM-probe
                path was unreliable).

                Plugin location:
                \(DSHPluginDetector.defaultPluginPath)

                Click "Install" to add the entry to your profile's
                cordis.patch.yml, or "Skip" to continue without the bridge
                (notifications will fall back to the old, unreliable path).
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Skip")
            if alert.runModal() == .alertFirstButtonReturn {
                let patchPath = Self.cordisPatchPath()
                do {
                    _ = try DSHPluginDetector.installPatchEntry(at: patchPath)
                } catch {
                    Log.pluginDetector.error("failed to install patch entry: \(error.localizedDescription, privacy: .public)")
                }
            }

        case .installedOutdated(let expected, let found):
            let alert = NSAlert()
            alert.messageText = "Plugin update available"
            alert.informativeText = """
                Installed: \(found)
                Expected:  \(expected)

                Run from the plugin directory:
                  git pull && npm run build

                Then restart DshDesktop.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")

        case .disabled:
            let alert = NSAlert()
            alert.messageText = "Plugin disabled — appears to be a misconfiguration"
            alert.informativeText = """
                The dsh-desktop-bridge patch row has `disabled: true` in your
                profile. This usually means a HOME-level patch or another plugin
                manager overrode it.

                Details:
                \(status.details)

                Click "Re-enable" to flip the flag back to enabled, or "Skip" to
                continue without the bridge.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Re-enable")
            alert.addButton(withTitle: "Skip")
            if alert.runModal() == .alertFirstButtonReturn {
                let patchPath = Self.cordisPatchPath()
                do {
                    _ = try DSHPluginDetector.reenablePatchEntry(at: patchPath)
                } catch {
                    Log.pluginDetector.error("failed to re-enable patch entry: \(error.localizedDescription, privacy: .public)")
                }
            }

        case .brokenPath(let path):
            let alert = NSAlert()
            alert.messageText = "Plugin file missing"
            alert.informativeText = """
                cordis.patch.yml points to:
                \(path)

                But that file does not exist. Either restore the plugin directory
                or update the patch row's `main:` field.

                Until fixed, DshDesktop will fall back to the old DOM-probe
                notification path.
                """
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
        }
    }

    /// Non-blocking variant of `checkBridgePluginAndAlertIfNeeded()` used
    /// at `init()` time. NSAlert.runModal() in SwiftUI's early-startup
    /// window race condition (the key window may not exist yet, the
    /// alert's runloop integration is fragile) — and a stuck modal there
    /// freezes the entire launch sequence. The "Check Bridge Plugin…"
    /// menu item uses the alert variant (called after the runloop is
    /// stable).
    ///
    /// For the launch-time path we:
    ///   - log the verdict (so `log show` still surfaces it),
    ///   - auto-install the patch for the safe `.notInstalled` case
    ///     (writing a YAML snippet is non-destructive and idempotent —
    ///     installPatchEntry checks for an existing entry first),
    ///   - leave the other verdicts for the user to handle via the menu
    ///     (a `.disabled` row probably means a deliberate user choice,
    ///     and `.brokenPath` / `.installedOutdated` need the user's eyes).
    private static func detectAndAutoInstallBridgePlugin() {
        if Self.launchConfig.help || Self.launchConfig.noSpawn { return }

        let dshHome = ProcessInfo.processInfo.environment["DSH_HOME"]
            ?? NSHomeDirectory() + "/.dsh"
        let status = DSHPluginDetector.detect(dshHome: dshHome)

        Log.pluginDetector.notice("bridge plugin detection verdict (auto-install): \(String(describing: status.state), privacy: .public)")

        switch status.state {
        case .installedCurrent, .disabled, .installedOutdated, .brokenPath:
            return // leave to the menu / user

        case .notInstalled:
            do {
                let wrote = try DSHPluginDetector.installPatchEntry(at: Self.cordisPatchPath())
                Log.pluginDetector.notice("bridge plugin patch auto-installed (wroteNew=\(wrote, privacy: .public))")
            } catch {
                Log.pluginDetector.error("bridge plugin auto-install failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

        /// Resolve the profile's `cordis.patch.yml` path from the same env vars
    /// `DshProcess` uses (DSH_HOME first, then $HOME/.dsh).
    private static func cordisPatchPath() -> String {
        let dshHome = ProcessInfo.processInfo.environment["DSH_HOME"]
            ?? NSHomeDirectory() + "/.dsh"
        return dshHome + "/profiles/web/cordis.patch.yml"
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

    /// Unix-domain socket server the dsh-desktop-bridge plugin connects to.
    /// Lives for the entire app lifetime. Not a `@StateObject` because
    /// DSHBridge is `@unchecked Sendable` (its I/O runs on a serial
    /// DispatchQueue; the wrapper code there is @MainActor-aware at the
    /// handler boundary but not at the class level).
    private var bridge: DSHBridge?

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

                Divider()

                // Manual plugin-status check. The auto-detection in
                // DshApp.init() runs once at launch, but the user may
                // want to re-check after editing cordis.patch.yml
                // outside the wrapper, or after a botched dsh update
                // wiped the patch entry.
                Button("Check Bridge Plugin…") {
                    Self.checkBridgePluginAndAlertIfNeeded()
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
        // Install the foreground-delivery delegate and ask for notification
        // permission up front. DshDesktop is a normal windowed app whose
        // window stays up while the agent runs; the delegate makes banners
        // appear even when frontmost, and asking here guarantees the system
        // auth prompt actually shows (the earlier .task placement never
        // surfaced it). Nested Task keeps it non-blocking — the wrapper
        // must boot even if the user dismisses the prompt.
        Notifications.installDelegate()
        Task { await Notifications.requestAuthorization() }
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
            // has finished building the menu bar. AppKit can re-insert the
            // auto menus whenever the SwiftUI scene body rebuilds the menu
            // bar (e.g. on window activation or a @StateObject change), so a
            // one-shot prune is not enough: observe menu additions and prune
            // on every change.
            Self.pruneAutoMenus()
            Self.armPruneObserver()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the bridge server cleanly so the plugin gets onQuit and the
        // socket file is unlinked. Best-effort: NSApp doesn't wait for
        // async cleanup at terminate, so we block the run loop briefly
        // (200 ms is the drain timeout inside DSHBridge.stop()).
        if let bridge = DshApp.sharedBridge {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await bridge.stop()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1.0)
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

        // Also log each item on its own line — joined strings lose
        // privacy metadata (each interpolation needs its own
        // privacy: .public spec for the redaction to be opted out).
        // `.notice` (not `.debug`) so it survives to the persisted store and
        // `log show` can confirm the menu state without a live stream.
        for (idx, item) in mainMenu.items.enumerated() {
            let title = item.submenu?.title ?? item.title
            let kind = item.submenu != nil ? "submenu" : "top-level"
            Log.app.notice("pruneAutoMenus: BEFORE  menu[\(idx, privacy: .public)] (\(kind, privacy: .public)) = \(title, privacy: .public)")
        }

        let dropTitles: Set<String> = [
            "File", "Edit", "Help", "Window", "View", "Format",
            "文件", "编辑", "帮助", "窗口", "显示", "视图", "格式",
        ]
        var keepGoing = true
        while keepGoing {
            keepGoing = false
            for (index, item) in mainMenu.items.enumerated() {
                if let title = item.submenu?.title, dropTitles.contains(title) {
                    Log.app.notice("pruneAutoMenus: removing submenu \(title, privacy: .public)")
                    mainMenu.removeItem(at: index)
                    keepGoing = true
                    break
                }
                if dropTitles.contains(item.title) {
                    Log.app.notice("pruneAutoMenus: removing top-level \(item.title, privacy: .public)")
                    mainMenu.removeItem(at: index)
                    keepGoing = true
                    break
                }
            }
        }
        // Log AFTER for confirmation.
        let afterTitles = mainMenu.items.map { ($0.submenu?.title ?? $0.title) as String }
        let joinedAfter = afterTitles.joined(separator: ", ")
        Log.app.notice("pruneAutoMenus: AFTER — \(joinedAfter, privacy: .public)")
        for (idx, item) in mainMenu.items.enumerated() {
            let title = item.submenu?.title ?? item.title
            let kind = item.submenu != nil ? "submenu" : "top-level"
            Log.app.debug("pruneAutoMenus: AFTER   menu[\(idx, privacy: .public)] (\(kind, privacy: .public)) = \(title, privacy: .public)")
        }
    }

    /// Observe additions to `NSApp.mainMenu` and prune again whenever AppKit
    /// inserts one of the auto menus (Help / Window / View). A one-shot prune
    /// at launch is unreliable because SwiftUI / AppKit can rebuild the menu
    /// bar later (window activation, scene re-evaluation) and re-insert them.
    /// Firing on `NSMenu.didAddItemNotification` removes them the moment they
    /// come back, with no polling.
    @MainActor
    static func armPruneObserver() {
        guard NSApp.mainMenu != nil else { return }
        let center = NotificationCenter.default
        // macOS posts NSMenu.didAddItemNotification when items are inserted
        // into a menu; posting an object is always nil for this one, so match
        // on the userInfo's menu instead.
        let prune: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated {
                Self.pruneAutoMenus()
            }
        }
        _ = center.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: nil,
            queue: .main,
            using: prune
        )
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