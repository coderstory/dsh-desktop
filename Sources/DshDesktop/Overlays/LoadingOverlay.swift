import SwiftUI

/// In-progress / "Waiting" overlay. Shown while the wrapper is starting
/// dsh or waiting for dsh's port to start serving.
struct LoadingOverlay: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)  // so user can copy the URL out
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
