import SwiftUI
import AppKit

/// Failure overlay shown when `DshProcess.state == .failed(reason)`.
/// Includes the full stderr tail in a scrollable monospaced block so the
/// user can see what went wrong (per the original "show complete error"
/// requirement).
struct FailedOverlay: View {
    let reason: String
    let stderrTail: String
    let onRestart: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("dsh failed to start")
                .font(.headline)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if !stderrTail.isEmpty {
                ScrollView {
                    Text(stderrTail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 200)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 8)
            }
            HStack(spacing: 12) {
                Button("Restart", action: onRestart)
                    .keyboardShortcut(.defaultAction)
                Button("Quit", action: onQuit)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
