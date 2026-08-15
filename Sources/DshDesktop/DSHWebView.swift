import SwiftUI
import WebKit

/// Wraps a WKWebView in a SwiftUI-compatible NSViewRepresentable.
/// `url` is fixed for the app lifetime because dsh serves a single origin.
struct DSHWebView: NSViewRepresentable {

    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        // Note: brief specified `config.allowsInlineMediaPlayback = true`, but
        // that property is iOS-only and not exposed on macOS. On macOS WebKit
        // already plays video inline by default, so no equivalent is needed.
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = false
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        // Reload if the URL changes (only on explicit user Reload).
        if wv.url != url {
            wv.load(URLRequest(url: url))
        }
    }
}
