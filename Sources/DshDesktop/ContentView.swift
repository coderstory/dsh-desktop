import SwiftUI
import AppKit

struct ContentView: View {

    @StateObject var process: DshProcess
    @ObservedObject var prefs: Preferences
    @ObservedObject var idleWatcher: AgentIdleWatcher
    @State private var webReady: Bool = false
    @State private var overlayHidden: Bool = false

    private var webURL: URL { URL(string: "http://127.0.0.1:\(process.port)/")! }

    var body: some View {
        ZStack {
            DSHWebView(
                url: webURL,
                onWebViewReady: { wv in
                    // Wire the running evaluator: poll dsh's UI for the
                    // streaming indicator on the configured interval.
                    idleWatcher.replaceEvaluator { [weak wv] in
                        guard let wv else { return false }
                        return await wv.dshIsAgentStreaming()
                    }
                    idleWatcher.reset()
                    idleWatcher.start()

                    // Also attach the WKWebView to the (optional) performance
                    // monitor. The monitor is enabled via Preferences and polls
                    // long-task counts + memory + plugin list from the page.
                    PerformanceMonitor.shared.attach(to: wv)
                    if Preferences.shared.enablePerformanceMonitoring {
                        PerformanceMonitor.shared.start()
                    }
                },
                onReload: {
                    idleWatcher.reset()
                }
            )
            .opacity(webReady ? 1 : 0)

            if !overlayHidden {
                overlay
                    .transition(.opacity)
            }
        }
        .task {
            await startFlow()
        }
        .onChange(of: process.state) { _, newState in
            handleStateChange(newState)
        }
        .onDisappear {
            idleWatcher.stop()
        }
        // (Polling-interval hot-reload is handled in DshApp's body, where
        // idleWatcher is the @StateObject — single source of truth.)
    }

    @ViewBuilder
    private var overlay: some View {
        switch process.state {
        case .idle, .starting:
            LoadingOverlay(title: "Starting dsh…", subtitle: nil)

        case .running where !webReady:
            LoadingOverlay(
                title: "Waiting for http://\(process.port)…",
                subtitle: nil
            )

        case .failed(let reason):
            FailedOverlay(
                reason: reason,
                stderrTail: process.stderrTail,
                onRestart: {
                    Task { await process.restart() }
                },
                onQuit: { NSApp.terminate(nil) }
            )

        case .running, .exited:
            EmptyView()
        }
    }

    private func startFlow() async {
        let port = process.port
        Log.ui.info("startFlow: pre-checking port \(port)")

        // Pre-check: if 3080 (or whatever port) is already serving, reuse
        // the externally-managed dsh — don't spawn, don't kill on quit.
        let alreadyUp = await DshHealthCheck.waitUntilReady(port: port, timeout: 1.5)
        if alreadyUp {
            Log.ui.info("startFlow: port \(port) already serving; reusing existing dsh")
            process.releaseOwnership()
            await process.start()  // sets state → .running (external mode)
            withAnimation(.easeIn(duration: 0.4)) { webReady = true }
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.easeOut(duration: 0.4)) { overlayHidden = true }
            return
        }

        // Port not responding — spawn our own dsh.
        Log.ui.info("startFlow: port \(port) refused; spawning dsh")
        await process.start()
        guard case .running = process.state else { return }

        // Wait up to 10s for dsh to bind the port.
        let ok = await DshHealthCheck.waitUntilReady(port: port, timeout: 10.0)
        if ok {
            withAnimation(.easeIn(duration: 0.4)) { webReady = true }
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.easeOut(duration: 0.4)) { overlayHidden = true }
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