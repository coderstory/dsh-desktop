import AppKit
@preconcurrency import WebKit

/// Local NSEvent monitor that intercepts Cmd+C / Cmd+V / Cmd+X / Cmd+A
/// BEFORE the responder chain and forwards them to the dsh WKWebView.
///
/// Why this exists: in the wrapper's ZStack, SwiftUI's container view
/// becomes the window's first responder by default. When the user presses
/// Cmd+C inside the dsh WebView, the keyDown is delivered to the
/// SwiftUI container (which does nothing), not the WKWebView (which
/// could perform the web's clipboard action). macOS's "first responder
/// walks up the chain" rule means the WebView never sees the event.
///
/// By intercepting at the local monitor level, we route Cmd+C/V/X/A
/// directly to the WebView's standard `copy(_:)` / `paste(_:)` /
/// `cut(_:)` / `selectAll(_:)` selectors, which delegate to the
/// underlying WKWebView's JavaScript bridge and trigger the web
/// content's standard browser clipboard behavior.
@MainActor
public final class HotkeyRouter {

    public static let shared = HotkeyRouter()

    public weak var webView: WKWebView?
    private var monitor: Any?

    private init() {}

    /// Begin monitoring. Idempotent.
    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  let wv = self.webView,
                  event.modifierFlags.contains(.command) else {
                return event  // pass through unchanged
            }
            // Standard clipboard + select-all shortcuts. Forward to the
            // WebView via the standard NSText actions, which WKWebView
            // implements by delegating to the web content's selection.
            // NSApp.sendAction walks the responder chain; passing `wv` as
            // the target starts there.
            let action: Selector?
            switch event.charactersIgnoringModifiers {
            case "c": action = #selector(NSText.copy(_:))
            case "v": action = #selector(NSText.paste(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            default: return event
            }
            if let action = action {
                NSApp.sendAction(action, to: wv, from: nil)
            }
            return nil  // consume — the WebView handled it
        }
        Log.ui.info("HotkeyRouter: installed Cmd+C/V/X/A → WKWebView forwarder")
    }

    public func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
            Log.ui.info("HotkeyRouter: stopped")
        }
    }

    /// Re-attach to a new webview. The router tracks the webview weakly
    /// so this is mostly useful when the DSHWebView rebuilds (e.g. on a
    /// preferences change that recreates the SwiftUI scene).
    public func bind(_ webView: WKWebView) {
        self.webView = webView
        if monitor == nil {
            start()
        }
    }
}
