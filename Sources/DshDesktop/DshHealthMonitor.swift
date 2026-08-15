import Foundation

/// Periodically pings dsh's port to detect when the process has died
/// (without us knowing). On the alive → dead transition, calls
/// `DshProcess.markFailedExternally` so the FailedOverlay surfaces.
///
/// Only active when the wrapper owns the dsh child (i.e. not in
/// `--no-spawn` mode, where the user manages dsh themselves).
@MainActor
public final class DshHealthMonitor: ObservableObject {

    public static let shared = DshHealthMonitor()

    public weak var process: DshProcess?
    public var interval: TimeInterval = 15.0

    private var task: Task<Void, Never>?
    private var lastPortAlive: Bool = true
    private var sampleCount: Int = 0

    public init() {}

    /// Attach the process to monitor. Idempotent.
    public func attach(to process: DshProcess) {
        self.process = process
    }

    /// Start polling. No-op if already running.
    public func start() {
        guard task == nil else { return }
        let interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        Log.ui.info("DshHealthMonitor: started (interval=\(interval)s)")
    }

    public func stop() {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        lastPortAlive = true   // reset for next start
        sampleCount = 0
        Log.ui.info("DshHealthMonitor: stopped")
    }

    public func sample() async {
        guard let p = process, p.ownsChild else { return }
        sampleCount += 1
        let alive = await DshHealthCheck.waitUntilReady(port: p.port, timeout: 1.5)
        // Debounce: ignore the first 2 samples (dsh may still be coming up
        // after a restart). After that, an alive→dead transition triggers.
        if sampleCount <= 2 {
            lastPortAlive = alive
            return
        }
        if lastPortAlive && !alive {
            Log.dsh.error("DshHealthMonitor: dsh port \(p.port) stopped responding")
            p.markFailedExternally(reason: "dsh stopped responding on port \(p.port)")
        }
        lastPortAlive = alive
    }

    /// Test-only: reset transient state.
    internal func _resetForTests() {
        stop()
        lastPortAlive = true
        sampleCount = 0
    }
}