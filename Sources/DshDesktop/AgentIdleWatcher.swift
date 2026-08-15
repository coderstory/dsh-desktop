import Foundation

/// Polls an evaluator closure (typically a `WKWebView.evaluateJavaScript`
/// wrapper) and fires a notification on the busy→idle transition, subject
/// to a cooldown. State machine is pure Swift — the evaluator closure is
/// injectable so tests don't need a real `WKWebView`.
@MainActor
public final class AgentIdleWatcher: ObservableObject {

    public enum State: Equatable {
        case idle
        case busy
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastNotifiedAt: Date?

    public typealias Evaluator = @MainActor () async -> Bool

    /// Settable at runtime — changes take effect on the next `runLoop` tick.
    /// Source of truth is `Preferences.shared.pollingIntervalSeconds`.
    public var pollInterval: TimeInterval

    private let cooldown: TimeInterval
    private var evaluator: Evaluator
    private let notify: (String, String) async -> Void
    private let isNotificationsEnabled: () -> Bool
    private var task: Task<Void, Never>?

    public init(
        pollInterval: TimeInterval = 5.0,
        cooldown: TimeInterval = 3.0,
        evaluator: @escaping Evaluator,
        notify: @escaping (String, String) async -> Void = Notifications.notify,
        isNotificationsEnabled: @escaping () -> Bool = { Preferences.shared.notificationsEnabled }
    ) {
        self.pollInterval = pollInterval
        self.cooldown = cooldown
        self.evaluator = evaluator
        self.notify = notify
        self.isNotificationsEnabled = isNotificationsEnabled
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func reset() {
        state = .idle
        lastNotifiedAt = nil
    }

    public func replaceEvaluator(_ newEvaluator: @escaping Evaluator) {
        evaluator = newEvaluator
    }

    // MARK: - Private

    private func runLoop() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private func tick() async {
        let isBusy = await evaluator()
        let newState: State = isBusy ? .busy : .idle
        guard newState != state else { return }
        state = newState

        // Fire notification only on busy → idle.
        guard case .idle = newState else { return }

        if let last = lastNotifiedAt,
           Date().timeIntervalSince(last) < cooldown {
            return
        }

        // Gate on user preference — toggling notifications off prevents
        // any new banners without affecting the cooldown clock.
        guard isNotificationsEnabled() else { return }

        lastNotifiedAt = Date()
        await notify(
            String(localized: "dsh"),
            String(localized: "Agent finished responding")
        )
    }
}
