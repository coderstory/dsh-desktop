import XCTest

/// Regression test for the launch-time hang reported in production: clicking
/// either "Install" or "Skip" in the bridge-plugin alert froze DshDesktop at
/// "Starting…". Root cause: NSAlert.runModal() was called from
/// `DshApp.init()` — a synchronous modal in SwiftUI's early-startup
/// runloop race. The fix split the function into:
///   * `detectAndAutoInstallBridgePlugin()` — called from init(), never
///     blocks, auto-installs the safe `.notInstalled` patch, logs the verdict.
///   * `checkBridgePluginAndAlertIfNeeded()` — only called from the
///     "Check Bridge Plugin…" menu item, after the runloop is stable.
///
/// The "non-blocking" claim is structural, not behavioural. We assert it
/// by reading DshApp.swift as text and verifying:
///   1. init() calls `detectAndAutoInstallBridgePlugin`, NOT the alerting
///      variant. The init() body must not reference `NSAlert`, `runModal`,
///      or `checkBridgePluginAndAlertIfNeeded`.
///   2. The non-blocking auto-install function body does not contain
///      `NSAlert` or `runModal`.
///   3. The alerting variant still uses NSAlert.runModal (it runs from
///      the menu where the runloop is stable — must keep its UX).
final class LaunchPathTests: XCTestCase {

    private let dshAppPath = "/Users/coderstory/CodeSource/dsh-desktop/Sources/DshDesktop/DshApp.swift"

    func test_init_doesNotCallAlertingPluginCheck() throws {
        let source = try String(contentsOfFile: dshAppPath, encoding: .utf8)
        let body = try Self.extractFunctionBody(source: source, signature: "    init() {")
        let code = Self.stripComments(body)
        XCTAssertTrue(code.contains("detectAndAutoInstallBridgePlugin"),
            "init() should call the non-blocking detectAndAutoInstallBridgePlugin")
        XCTAssertFalse(code.contains("checkBridgePluginAndAlertIfNeeded"),
            "init() must not call checkBridgePluginAndAlertIfNeeded (runModal hangs launch)")
        XCTAssertFalse(code.contains("NSAlert"),
            "init() must not import or use NSAlert (modal hangs launch)")
        XCTAssertFalse(code.contains("runModal"),
            "init() must not contain runModal — that freezes the launch sequence")
    }

    func test_autoInstallFunction_doesNotUseAppKit() throws {
        let source = try String(contentsOfFile: dshAppPath, encoding: .utf8)
        let body = try Self.extractFunctionBody(
            source: source,
            signature: "    private static func detectAndAutoInstallBridgePlugin() {"
        )
        let code = Self.stripComments(body)
        XCTAssertFalse(code.contains("NSAlert"),
            "detectAndAutoInstallBridgePlugin must not use NSAlert")
        XCTAssertFalse(code.contains("runModal"),
            "detectAndAutoInstallBridgePlugin must not call runModal")
    }

    func test_alertingPluginCheck_stillUsesAppKit() throws {
        let source = try String(contentsOfFile: dshAppPath, encoding: .utf8)
        let body = try Self.extractFunctionBody(
            source: source,
            signature: "    private static func checkBridgePluginAndAlertIfNeeded() {"
        )
        let code = Self.stripComments(body)
        XCTAssertTrue(code.contains("NSAlert"),
            "checkBridgePluginAndAlertIfNeeded should still use NSAlert (menu path is interactive)")
        XCTAssertTrue(code.contains("runModal"),
            "checkBridgePluginAndAlertIfNeeded should still call runModal (menu path is interactive)")
    }

    /// Extract a top-level (4-space-indent) static function body from a
    /// Swift source string by walking brace depth. Returns the text
    /// between the function's `{` and its matching `}`.
    private static func extractFunctionBody(source: String, signature: String) throws -> String {
        // Convert to [Character] and search by string-equality. String.Index
        // math on non-ASCII sources trips utf16Offset; character array is
        // always safe to index by Int.
        let chars = Array(source)
        let sigChars = Array(signature)
        guard chars.count >= sigChars.count else {
            throw NSError(domain: "LaunchPathTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "source shorter than signature"])
        }
        // Find the signature in the character array.
        var openBraceOffset = -1
        outer: for i in 0...(chars.count - sigChars.count) {
            for k in 0..<sigChars.count where chars[i + k] != sigChars[k] {
                continue outer
            }
            // Match — openBraceOffset is the position of the LAST char
            // of the signature, which is `{`.
            openBraceOffset = i + sigChars.count - 1
            break
        }
        guard openBraceOffset != -1 else {
            throw NSError(domain: "LaunchPathTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "signature not found"])
        }
        return try scanBody(chars: chars, openBraceOffset: openBraceOffset)
    }

    /// Scan from the `{` at `openBraceOffset` in `chars` to its matching `}`,
    /// returning the substring between them.
    private static func scanBody(chars: [Character], openBraceOffset: Int) throws -> String {
        guard openBraceOffset >= 0, openBraceOffset < chars.count else {
            throw NSError(domain: "LaunchPathTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "openBraceOffset out of range"])
        }
        guard chars[openBraceOffset] == "{" else {
            throw NSError(domain: "LaunchPathTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "expected `{` at openBraceOffset"])
        }
        var depth = 0
        var endOffset = -1
        for k in openBraceOffset..<chars.count {
            let c = chars[k]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { endOffset = k; break }
            }
        }
        guard depth == 0, endOffset > openBraceOffset else {
            throw NSError(domain: "LaunchPathTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "unbalanced braces: depth=\(depth) end=\(endOffset) open=\(openBraceOffset)"])
        }
        // String(chars[range]) can trap on bad indices. Build the
        // substring char-by-char for safety.
        var body = ""
        for k in (openBraceOffset + 1)..<endOffset {
            body.append(chars[k])
        }
        return body
    }

    /// Strip Swift line (`//`) and block (`/* ... */`) comments from a chunk
    /// of source so that textual guards aren't tripped by legitimate
    /// doc-comments mentioning the APIs we're guarding against. String
    /// literals aren't handled (we don't have any in the test targets).
    private static func stripComments(_ s: String) -> String {
        // Convert to character array for safe Int indexing.
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            if i + 1 < chars.count {
                let two: [Character] = [chars[i], chars[i + 1]]
                if two == ["/", "/"] {
                    // Skip to end of line.
                    if let nl = chars[i...].firstIndex(of: "\n") {
                        i = nl + 1
                    } else {
                        break
                    }
                    continue
                }
                if two == ["/", "*"] {
                    // Skip to */ .
                    var k = i + 2
                    while k + 1 < chars.count {
                        if chars[k] == "*" && chars[k + 1] == "/" { break }
                        k += 1
                    }
                    i = k + 2
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }
}