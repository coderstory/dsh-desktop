//
//  SettingsWindowController.swift
//  DshDesktop
//
//  Singleton NSWindowController that creates the Settings window with
//  .fullSizeContentView for liquid glass rendering on macOS 26. Used
//  instead of SwiftUI's `Settings { ... } }` scene because the scene
//  API doesn't expose the NSWindow style mask needed for the rounded
//  corners + translucent sidebar treatment.
//
//  Usage:
//    SettingsWindowController.show()              // first tab
//    SettingsWindowController.show(tab: .general) // jump to a tab
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    /// Show the settings window, optionally jumping to a specific tab.
    static func show(tab: SettingsTab? = nil) {
        if let tab {
            SettingsNavigation.shared.selectedTab = tab
        }
        if shared == nil {
            shared = SettingsWindowController()
        }
        shared?.showWindow(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 720, height: 540)),
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .miniaturizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureWindow() {
        guard let window else { return }

        window.title = "Settings"
        window.titleVisibility = .visible
        window.toolbarStyle = .automatic
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("DshDesktop.SettingsWindow")
        window.minSize = NSSize(width: 620, height: 460)
        window.center()
        window.delegate = self

        let hostingController = NSHostingController(rootView: SettingsView())
        window.contentViewController = hostingController
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}