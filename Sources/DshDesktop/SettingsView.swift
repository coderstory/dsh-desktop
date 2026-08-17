//
//  SettingsView.swift
//  DshDesktop
//
//  Root settings view with NavigationSplitView sidebar + detail, back/
//  forward toolbar navigation, and liquid glass support on macOS 26.
//
//  Pane dispatch lives in SettingsDetailView. Each pane file owns its
//  own Form/Section structure with `.formStyle(.grouped) +
//  .scrollContentBackground(.hidden)` modifiers applied at the root.
//

import SwiftUI

// MARK: - Tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case system
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general:  "General"
        case .system:   "System"
        case .about:    "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:  "slider.horizontal.3"
        case .system:   "gearshape.2"
        case .about:    "info.circle"
        }
    }
}

// MARK: - Navigation state

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab: SettingsTab = .general
    private init() {}
}

// MARK: - Version helper

private enum AppVersion {
    static let displayString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (\(build))"
    }()
}

// MARK: - Root view

struct SettingsView: View {
    // `@Bindable` is the correct wrapper for an `@Observable` reference — it
    // gives us `$navigation.selectedTab` for free, and SwiftUI's observation
    // system tracks property mutations on the singleton directly. Using
    // `@State` to wrap the singleton (the previous setup) compiled fine but
    // shadowed the @Observable observation: the sidebar List's selection
    // binding was attached to a stale snapshot, leaving rows unselected and
    // — on macOS 27's NavigationSplitView sidebar renderer — visually blank.
    @Bindable private var navigation = SettingsNavigation.shared
    @State private var navigationHistory: [SettingsTab] = [.general]
    @State private var historyIndex = 0
    @State private var isHistoryNavigation = false

    private var activeTab: SettingsTab {
        navigation.selectedTab
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebarView(selectedTab: $navigation.selectedTab)
                .frame(width: 200)
                .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetailView(prefs: Preferences.shared, tab: activeTab)
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 660, minHeight: 540)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoBack)

                Button {
                    goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canGoForward)
            }
        }
        .onChange(of: navigation.selectedTab) { _, _ in
            recordNavigation()
        }
    }

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex < navigationHistory.count - 1 }

    private func goBack() {
        guard canGoBack else { return }
        isHistoryNavigation = true
        historyIndex -= 1
        navigation.selectedTab = navigationHistory[historyIndex]
        DispatchQueue.main.async { isHistoryNavigation = false }
    }

    private func goForward() {
        guard canGoForward else { return }
        isHistoryNavigation = true
        historyIndex += 1
        navigation.selectedTab = navigationHistory[historyIndex]
        DispatchQueue.main.async { isHistoryNavigation = false }
    }

    private func recordNavigation() {
        guard !isHistoryNavigation else { return }
        let tab = navigation.selectedTab
        if navigationHistory.last == tab { return }
        if historyIndex < navigationHistory.count - 1 {
            navigationHistory = Array(navigationHistory.prefix(historyIndex + 1))
        }
        navigationHistory.append(tab)
        historyIndex = navigationHistory.count - 1
    }
}

// MARK: - Sidebar

private struct SettingsSidebarView: View {
    @Binding var selectedTab: SettingsTab

    var body: some View {
        List(selection: $selectedTab) {
            // No explicit `.tag(tab)` — `Identifiable` conformance already
            // tags each row by `tab.id` (== `tab` itself). The redundant
            // `.tag(tab)` was harmless on its own, but together with the
            // optional Binding<SettingsTab?> + non-optional tag mismatch
            // it pushed the sidebar List into a state where row bodies
            // weren't being laid out on macOS 27's NavigationSplitView.
            ForEach(SettingsTab.allCases) { tab in
                SettingsSidebarRow(tab: tab)
            }
            SettingsSidebarFooter()
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectStyleSoftIfAvailable()
        .navigationTitle("Settings")
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab
    var body: some View {
        Label {
            Text(tab.title)
        } icon: {
            Image(systemName: tab.systemImage)
        }
        .foregroundStyle(.primary)
    }
}

private struct SettingsSidebarFooter: View {
    var body: some View {
        Text(AppVersion.displayString)
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .fontDesign(.monospaced)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
    }
}

// MARK: - Detail dispatch

private struct SettingsDetailView: View {
    @ObservedObject var prefs: Preferences
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general:  GeneralSettingsPane(prefs: prefs)
            case .system:   SystemSettingsPane(prefs: prefs)
            case .about:    AboutSettingsPane()
            }
        }
        .navigationTitle(tab.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - macOS 26 helpers

private extension View {
    @ViewBuilder
    func scrollEdgeEffectStyleSoftIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}