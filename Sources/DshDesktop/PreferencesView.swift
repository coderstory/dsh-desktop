import SwiftUI

/// Settings window content. Opened via the standard macOS Cmd+, menu item
/// (`Settings { ... }` scene in `DshApp`).
struct PreferencesView: View {

    @ObservedObject var prefs: Preferences
    @State private var portText: String = ""

    var body: some View {
        Form {
            Section {
                PortFieldRow(prefs: prefs, portText: $portText)
            } header: {
                Text("Server").font(.headline)
            }

            Section {
                Toggle("Show notification when dsh finishes", isOn: $prefs.notificationsEnabled)
                    .help("A macOS banner appears when the dsh agent finishes its response.")
            } header: {
                Text("Notifications").font(.headline)
            }

            Section {
                PollingIntervalRow(seconds: $prefs.pollingIntervalSeconds)
                    .help("How often DshDesktop checks the dsh UI for the busy/idle indicator.")
                Toggle("Pause polling when window is hidden", isOn: $prefs.pausePollingWhenHidden)
                    .help("Stops the DOM polling loop while the main window is closed. Resumes when you reopen the window. Saves a small amount of CPU; note that dsh's own CPU usage from its UI/plugins is unaffected.")
            } header: {
                Text("Polling").font(.headline)
            }

            Section {
                Toggle("Enable browser performance monitor", isOn: $prefs.enablePerformanceMonitoring)
                    .help("Polls dsh's UI every 10s for long-running tasks (>100ms), JS heap usage, and a list of currently-loaded plugins. Adds a 'Performance' item to the menu bar; click for details. Off by default.")
            } header: {
                Text("Diagnostics").font(.headline)
            }

            Section {
                Button("Reset to Defaults") {
                    prefs.resetToDefaults()
                    portText = String(prefs.port)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 440)
        .onAppear {
            portText = String(prefs.port)
        }
    }
}

private struct PortFieldRow: View {
    @ObservedObject var prefs: Preferences
    @Binding var portText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Port")
                TextField("Port", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Button("Apply") {
                    if let p = Int(portText), p > 0, p < 65536 {
                        prefs.port = p
                    } else {
                        // Revert to current value
                        portText = String(prefs.port)
                    }
                }
                .disabled(parsedPort == nil || parsedPort == prefs.port)
            }
            Text("dsh listens on this port. Restart dsh (dsh menu) to apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var parsedPort: Int? {
        guard let p = Int(portText), p > 0, p < 65536 else { return nil }
        return p
    }
}

private struct PollingIntervalRow: View {
    @Binding var seconds: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Slider(value: $seconds,
                       in: Preferences.pollingIntervalRange,
                       step: 1)
                Text("\(Int(seconds))s")
                    .frame(width: 36, alignment: .trailing)
                    .monospacedDigit()
            }
            Text("Range: \(Int(Preferences.pollingIntervalRange.lowerBound))s – \(Int(Preferences.pollingIntervalRange.upperBound))s. Default: \(Int(Preferences.defaultPollingIntervalSeconds))s.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}