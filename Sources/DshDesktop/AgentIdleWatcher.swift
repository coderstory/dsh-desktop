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

    /// Fixed interval between idle-probe polls. Not user-tunable.
    public let pollInterval: TimeInterval

    private let cooldown: TimeInterval
    /// Minimum time an idle sample must persist before the "finished
    /// responding" notification fires. The probe can briefly read idle
    /// between tool calls / during reasoning gaps while dsh is still working
    /// (it only sees `data-streaming=true` while markdown is actively
    /// streaming); a true finish must survive this settle window.
    private let idleConfirmationDelay: TimeInterval
    private var evaluator: Evaluator
    private let notify: (String, String) async -> Void
    private let isNotificationsEnabled: () -> Bool
    private var task: Task<Void, Never>?
    /// When the current idle run began (set on the first idle sample after a
    /// busy read). Reset to nil on any busy sample.
    private var idleSince: Date?
    /// True once any busy sample has been observed. The completion
    /// notification is only meaningful after an agent started running, so a
    /// session that opened straight into idle must not fire.
    private var everBusy: Bool = false
    /// Whether the current idle episode already fired, so we don't re-fire on
    /// later polls once the confirmation window has passed.
    private var firedForEpisode: Bool = false

    public init(
        pollInterval: TimeInterval = 5.0,
        cooldown: TimeInterval = 3.0,
        idleConfirmationDelay: TimeInterval = 3.0,
        evaluator: @escaping Evaluator,
        notify: @escaping (String, String) async -> Void = Notifications.notify,
        isNotificationsEnabled: @escaping () -> Bool = { Preferences.shared.notificationsEnabled }
    ) {
        self.pollInterval = pollInterval
        self.cooldown = cooldown
        self.idleConfirmationDelay = max(0, idleConfirmationDelay)
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
        idleSince = nil
        everBusy = false
        firedForEpisode = false
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

        // Update the published state immediately on every sample so the UI
        // overlay reflects the live busy/idle indicator.
        if newState != state {
            state = newState
        }

        if isBusy {
            idleSince = nil
            firedForEpisode = false
            everBusy = true
            return
        }

        // Idle sample. Record when this idle run began (once), then require
        // it to persist for `idleConfirmationDelay` before we believe the
        // agent really finished. A single idle gap between tool calls / during
        // a reasoning stretch is shorter than the delay and never fires.
        if idleSince == nil {
            idleSince = Date()
        }
        // Never notify if we never observed the agent working.
        guard everBusy else { return }
        // Have we confirmed (persisted long enough) and not already fired?
        guard !firedForEpisode else { return }
        guard Date().timeIntervalSince(idleSince!) >= idleConfirmationDelay else { return }

        if let last = lastNotifiedAt,
           Date().timeIntervalSince(last) < cooldown {
            return
        }

        // Gate on user preference — toggling notifications off prevents
        // any new banners without affecting the cooldown clock.
        guard isNotificationsEnabled() else { return }

        firedForEpisode = true
        lastNotifiedAt = Date()
        Log.dsh.notice("idleProbe: idle persisted \(self.idleConfirmationDelay, privacy: .public)s — firing notification")
        await notify(
            String(localized: "dsh"),
            String(localized: "Agent finished responding")
        )
    }
}
