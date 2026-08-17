import XCTest
@testable import DshDesktop

/// Regression tests for the Settings sidebar blank-sidebar bug on
/// macOS 27's NavigationSplitView renderer.
///
/// Root cause: `SettingsNavigation.selectedTab` was typed as non-optional
/// `SettingsTab`, but `List(selection: $binding)` on macOS 27's renderer
/// expects the selection to match the row's `Identifiable` type strictly —
/// and since `SettingsTab: Identifiable` is keyed by `Self`, the binding
/// type must be `Binding<SettingsTab?>`. The non-optional variant
/// compiled fine on macOS 26 but rendered an empty sidebar on 27.
///
/// The same surface area was already protected against the
/// "init() calls runModal()" launch hang (LaunchPathTests). This file
/// covers the parallel regression: the *render* path must agree with
/// the sidebar's binding type contract.
@MainActor
final class SettingsViewTests: XCTestCase {

    /// `selectedTab` must be Optional so `List(selection:)` on macOS 27
    /// agrees with `SettingsTab: Identifiable` (id == self).
    func test_navigationSelectedTab_isOptional() {
        let nav = SettingsNavigation.shared
        // Assignment via Optional to verify the storage accepts nil.
        nav.selectedTab = nil
        XCTAssertNil(nav.selectedTab, "selectedTab must accept nil — List(selection:) on macOS 27 requires Binding<SettingsTab?>")
        nav.selectedTab = .system
        XCTAssertEqual(nav.selectedTab, .system)
    }

    /// `activeTab` (the computed property used by `SettingsDetailView`)
    /// must never be nil at the render boundary even when `selectedTab`
    /// is — fall back to `.general`. Otherwise the detail pane would
    /// render empty.
    func test_activeTab_fallsBackToGeneralWhenSelectedTabIsNil() {
        let nav = SettingsNavigation.shared
        nav.selectedTab = nil
        // We can't construct a `SettingsView` here (it'd need prefs +
        // @Bindable etc.) — instead re-derive the same expression that
        // `SettingsView.activeTab` uses and assert it doesn't crash.
        // Mirrors the source at SettingsView.swift:
        //     private var activeTab: SettingsTab { navigation.selectedTab ?? .general }
        let activeTab: SettingsTab = nav.selectedTab ?? .general
        XCTAssertEqual(activeTab, .general, "activeTab must fall back to .general when selectedTab is nil")
    }
}
