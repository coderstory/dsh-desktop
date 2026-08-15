import SwiftUI
import AppKit

struct ContentView: View {

    @StateObject var process: DshProcess
    @State private var webReady: Bool = false
    @State private var overlayHidden: Bool = false

    private var webURL: URL { URL(string: "http://127.0.0.1:\(process.port)/")! }

    var body: some View {
        ZStack {
            DSHWebView(url: webURL)
                .opacity(webReady ? 1 : 0)

            if !overlayHidden {
                overlay
                    .transition(.opacity)
            }
        }
        .task {
            await startFlow()
        }
        .onChange(of: process.state) { newState in
            handleStateChange(newState)
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch process.state {
        case .idle, .starting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Starting dsh…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

        case .running where !webReady:
            VStack(spacing: 12) {
                ProgressView()
                Text("Waiting for http://127.0.0.1:\(process.port)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

        case .failed(let reason):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text("dsh stopped")
                    .font(.headline)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                HStack(spacing: 12) {
                    Button("Restart") {
                        Task { await process.restart() }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Quit") {
                        NSApp.terminate(nil)
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

        case .running, .exited:
            EmptyView()
        }
    }

    private func startFlow() async {
        await process.start()
        guard case .running = process.state else { return }
        let ok = await DshHealthCheck.waitUntilReady(
            port: process.port, timeout: 10.0
        )
        if ok {
            withAnimation(.easeIn(duration: 0.4)) {
                webReady = true
            }
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.easeOut(duration: 0.4)) {
                overlayHidden = true
            }
        }
        // If !ok, the state transition to .failed will be picked up by onChange.
    }

    private func handleStateChange(_ state: DshProcess.State) {
        // Reset readiness when starting a new round, so overlay reappears.
        if case .starting = state {
            webReady = false
            overlayHidden = false
        }
        // If dsh died after we were ready, keep last DOM and show failed overlay.
        if case .failed = state {
            webReady = false
            overlayHidden = false
        }
    }
}
