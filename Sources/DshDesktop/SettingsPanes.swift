//
//  SettingsPanes.swift
//  DshDesktop
//
//  Detail panes for the Settings window. Each pane uses Form + Section
//  with `.formStyle(.grouped) + .scrollContentBackground(.hidden)
//  + .contentMargins(.top, 8, for: .scrollContent)` so the liquid glass
//  window chrome shows through (per macos-settings-ui skill).
//
//  State is bound to `Preferences.shared` so changes hot-reload into
//  the running components (AgentIdleWatcher, PerformanceMonitor, etc.).
//

import SwiftUI

// MARK: - General pane

struct GeneralSettingsPane: View {
    @ObservedObject var prefs: Preferences
    @State private var portText: String = ""

    var body: some View {
        Form {
            Section("Server") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(localized: "TCP port"))
                        TextField(String(localized: "Port"), text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Button(String(localized: "Apply")) {
                            if let p = Int(portText), p > 0, p < 65536 {
                                prefs.port = p
                            } else {
                                portText = String(prefs.port)
                            }
                        }
                        .controlSize(.small)
                        .disabled(parsedPort == nil || parsedPort == prefs.port)
                    }
                    Text(String(localized: "dsh listens on this port. Restart dsh (dsh menu) to apply."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Notifications") {
                Toggle(isOn: $prefs.notificationsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Show notification when dsh finishes"))
                        Text(String(localized: "A macOS banner appears when the dsh agent finishes its response."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Section("Polling") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Slider(value: $prefs.pollingIntervalSeconds,
                               in: Preferences.pollingIntervalRange,
                               step: 1)
                            .frame(width: 220)
                        Text("\(Int(prefs.pollingIntervalSeconds))s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    Text(String(localized: "How often DshDesktop checks the dsh UI for the busy/idle indicator."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $prefs.pausePollingWhenHidden) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Pause polling when window is hidden"))
                        Text(String(localized: "Stops the DOM polling loop while the main window is closed. Resumes when you reopen."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Section("Diagnostics") {
                Toggle(isOn: $prefs.enablePerformanceMonitoring) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Enable browser performance monitor"))
                        Text(String(localized: "Polls dsh's UI every 10s for long-running tasks (>100 ms), JS heap usage, and a list of currently-loaded plugins."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Section {
                Button(String(localized: "Reset to Defaults")) {
                    prefs.resetToDefaults()
                    portText = String(prefs.port)
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            portText = String(prefs.port)
        }
    }

    private var parsedPort: Int? {
        guard let p = Int(portText), p > 0, p < 65536 else { return nil }
        return p
    }
}

// MARK: - System pane

struct SystemSettingsPane: View {
    @ObservedObject var prefs: Preferences
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled()

    var body: some View {
        Form {
            Section("Login") {
                Toggle(isOn: $launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Launch DshDesktop at login"))
                        Text(String(localized: "Automatically start DshDesktop when you sign in. Uses macOS Launch Services (SMAppService); doesn't add a Login Item."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: launchAtLogin) { _, newValue in
                    // Toggle the registered state. The system is best-effort;
                    // we don't surface errors to the user here — they'll see
                    // the toggle "stick" if registration actually succeeded.
                    LaunchAtLogin.toggle()
                    // Re-read to reflect ground truth.
                    launchAtLogin = LaunchAtLogin.isEnabled()
                }
            }

            Section(String(localized: "Reset")) {
                Button(String(localized: "Reset to Defaults")) {
                    prefs.resetToDefaults()
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

// MARK: - About pane

struct AboutSettingsPane: View {
    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("DshDesktop")
                            .font(.largeTitle.bold())
                        Text(AppVersionExposed.displayString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(String(localized: "Native macOS wrapper for dsh --profile web"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(String(localized: "Links")) {
                Link(String(localized: "dsh 资源导航"),
                     destination: URL(string: "https://dshfind.com/zh")!)
                Link(String(localized: "Awesome dsh Plugins"),
                     destination: URL(string: "https://awesome-dsh-plugin.com/zh/")!)
            }

            Section(String(localized: "Credits")) {
                Text(String(localized: "Built as a thin native SwiftUI shell around `@deepseek-ai/dsh`."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

// MARK: - Version display (exposed for footer)

enum AppVersionExposed {
    static let displayString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (\(build))"
    }()
}