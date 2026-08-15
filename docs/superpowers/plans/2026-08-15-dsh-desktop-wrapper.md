# DSH Desktop Wrapper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wrap the dsh web service (port 3080) inside a native macOS SwiftUI app so the user has a dedicated Dock icon, a real window, and macOS menu/window affordances instead of opening Chrome and bookmarking the localhost URL.

**Architecture:** Single Swift Package with one executable target using `SwiftUI.App` lifecycle. A hosted `WKWebView` loads `http://127.0.0.1:3080`. A `DshProcess` ObservableObject owns the child `Process` that runs `dsh --profile web`, surfaces state to two SwiftUI overlays (starting / failed). A `scripts/bundle.sh` wraps the SwiftPM output into a `.app` bundle and `scripts/sign.sh` ad-hoc-signs it.

**Tech Stack:**
- Swift 6.4 + Swift Package Manager (no `.xcodeproj`)
- macOS 13.0+ deployment target (verified: actual env is 27.0)
- SwiftUI + AppKit (`NSWindowRepresentable`, `NSViewRepresentable`)
- WebKit (`WKWebView`)
- Swift Testing (`@Test`, `#expect`) — XCTest-compatible test target
- bash for the build/sign scripts

**Spec:** `/Users/coderstory/CodeSource/dsh-desktop/docs/superpowers/specs/2026-08-15-dsh-desktop-wrapper-design.md`

## Global Constraints

- macOS deployment target: **13.0** (spec §4.1)
- Backend port: **127.0.0.1:3080** hardcoded — no discovery (spec §5.1, user decision)
- `dsh` resolved from user's `$PATH` (spec §12 risk; user owns dsh install)
- App bundle id: **`ai.deepseek.dsh.desktop`** (spec §9.1)
- Bundle display name: **DshDesktop**
- Window initial size: **1200×800**, min **800×500**, title **"dsh"** (spec §7.1)
- No third-party deps — Apple SDKs only
- No credentials, no remote URLs except `127.0.0.1:3080`
- All UI strings English; no localization in v1
- Every task ends with `git commit`
- Implementation project root: `/Users/coderstory/CodeSource/dsh-desktop` (already initialized as git repo; commits continue here)

---

### Task 1: Swift Package skeleton + smoke-build

**Files:**
- Create: `/Users/coderstory/CodeSource/dsh-desktop/Package.swift`
- Create: `/Users/coderstory/CodeSource/dsh-desktop/Sources/DshDesktop/DshApp.swift`
- Create: `/Users/coderstory/CodeSource/dsh-desktop/Tests/DshDesktopTests/SmokeTests.swift`
- Create: `/Users/coderstory/CodeSource/dsh-desktop/.gitignore`

**Interfaces:**
- None — this task only verifies the build.

- [ ] **Step 1: Verify Swift toolchain**

Run: `swift --version`
Expected: Swift 6.x available (env confirmed 6.4). If older, stop and ask user to upgrade Xcode.

- [ ] **Step 2: Create `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DshDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DshDesktop", targets: ["DshDesktop"]),
    ],
    targets: [
        .executableTarget(
            name: "DshDesktop",
            path: "Sources/DshDesktop"
        ),
        .testTarget(
            name: "DshDesktopTests",
            dependencies: ["DshDesktop"],
            path: "Tests/DshDesktopTests"
        ),
    ]
)
```

- [ ] **Step 3: Create `Sources/DshDesktop/DshApp.swift`**

```swift
import SwiftUI

@main
struct DshApp: App {
    var body: some Scene {
        Window("dsh", id: "main") {
            Text("dsh — placeholder")
                .frame(width: 400, height: 200)
        }
    }
}
```

- [ ] **Step 4: Create `Tests/DshDesktopTests/SmokeTests.swift`**

```swift
import Testing
@testable import DshDesktop

@Test func appStructExists() {
    // Sanity check that DshApp compiles in test target.
    let _: AnyObject.Type = DshApp.self as AnyObject.Type
}
```

- [ ] **Step 5: Create `.gitignore`**

```
.DS_Store
.build/
.swiftpm/
.build/*
Package.resolved
build/
*.xcodeproj/
```

- [ ] **Step 6: Verify build**

Run:
```bash
cd /Users/coderstory/CodeSource/dsh-desktop && swift build 2>&1 | tail -20
```
Expected: `Build complete!` line. Any error must be fixed before continuing.

- [ ] **Step 7: Verify test target compiles**

Run:
```bash
swift test --filter SmokeTests 2>&1 | tail -20
```
Expected: 1 test passed.

- [ ] **Step 8: Commit**

```bash
cd /Users/coderstory/CodeSource/dsh-desktop
git add Package.swift Sources Tests .gitignore
git commit -m "chore: bootstrap Swift Package with placeholder app"
```

---

### Task 2: `DshProcess` — process wrapper with state machine (TDD)

**Files:**
- Create: `/Users/coderstory/CodeSource/dsh-desktop/Sources/DshDesktop/DshProcess.swift`
- Create: `/Users/coderstory/CodeSource/dsh-desktop/Tests/DshDesktopTests/DshProcessTests.swift`

**Interfaces (consumed by later tasks):**
- `class DshProcess: ObservableObject`
- `@Published var state: DshProcess.State`
- `enum DshProcess.State: Equatable { case idle, starting, running, exited, failed(String) }`
- `init(executable: URL, arguments: [String], port: Int)`
- `func start() async`
- `func stop(timeout: TimeInterval = 2.0) async`
- `func restart() async`
- `var stderrTail: String { get }` (read-only snapshot, max 64 KiB)

We build `DshProcess` parameterized by an `executable` URL and `arguments`, **not** a hardcoded `dsh` literal. This makes the unit tests independent of `dsh` being on the test machine. The production code in Task 5 wires `executable: URL(fileURLWithPath: "/usr/bin/env")`, `arguments: ["dsh", "--profile", "web"]`.

- [ ] **Step 1: Write the failing tests**

`Tests/DshDesktopTests/DshProcessTests.swift`:

```swift
import Testing
import Foundation
@testable import DshDesktop

@Suite("DshProcess")
struct DshProcessTests {

    @Test func start_withEcho_spawnsAndTransitionsToRunning() async throws {
        let proc = DshProcess(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            port: 3080
        )
        await proc.start()
        // /bin/echo exits immediately; we should observe either .running (handler fired)
        // or .exited depending on timing. Either is acceptable evidence of "spawn worked".
        let observed: Set<DshProcess.State> = [proc.state, .exited]
        _ = observed  // assert no crash; final state is one of these.
        // Give the termination handler time to fire.
        try await Task.sleep(for: .milliseconds(150))
        #expect(proc.state != .idle)
        #expect(proc.state != .starting)
    }

    @Test func start_withNonexistentExecutable_transitionsToFailed() async throws {
        let proc = DshProcess(
            executable: URL(fileURLWithPath: "/nonexistent/binary/abc"),
            arguments: [],
            port: 3080
        )
        await proc.start()
        try await Task.sleep(for: .milliseconds(200))
        if case .failed = proc.state {
            // ok
        } else {
            Issue.record("expected .failed, got \(proc.state)")
        }
    }

    @Test func stop_afterStart_terminatesTheChild() async throws {
        let proc = DshProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            port: 3080
        )
        await proc.start()
        #expect(proc.state == .running || proc.state == .starting)
        await proc.stop(timeout: 1.0)
        if case .failed = proc.state {
            // acceptable if sleep was already gone
        } else {
            #expect(proc.state == .exited)
        }
    }

    @Test func restart_invokesStartAgain() async throws {
        let proc = DshProcess(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["one"],
            port: 3080
        )
        await proc.start()
        try await Task.sleep(for: .milliseconds(100))
        let firstState = proc.state
        await proc.restart()
        try await Task.sleep(for: .milliseconds(100))
        #expect(proc.state != firstState || proc.state == .exited)
    }

    @Test func stateIsIdleBeforeStart() {
        let proc = DshProcess(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            port: 3080
        )
        #expect(proc.state == .idle)
    }
}
```

- [ ] **Step 2: Run the tests — confirm they fail (no implementation yet)**

Run: `swift test --filter DshProcessTests 2>&1 | tail -15`
Expected: Build failure — "cannot find type 'DshProcess' in scope".

- [ ] **Step 3: Implement `Sources/DshDesktop/DshProcess.swift`**

```swift
import Foundation

/// Owns a child `Process` that runs the dsh web backend.
/// Exposes lifecycle as a state machine for SwiftUI overlays.
@MainActor
public final class DshProcess: ObservableObject {

    public enum State: Equatable {
        case idle
        case starting
        case running
        case exited
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    public private(set) var stderrTail: String = ""

    private let executable: URL
    private let arguments: [String]
    private let port: Int
    private var process: Process?
    private var stderrPipe: Pipe?
    private let stderrCap = 64 * 1024  // 64 KiB

    public init(executable: URL, arguments: [String], port: Int) {
        self.executable = executable
        self.arguments = arguments
        self.port = port
    }

    public func start() async {
        guard state == .idle || if case .failed = state { false } else { true }
                || if case .exited = state { false } else { state == .idle } else {
            return
        }
        await launch()
    }

    public func stop(timeout: TimeInterval = 2.0) async {
        guard let proc = process, proc.isRunning else {
            state = .exited
            return
        }
        proc.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if proc.isRunning {
            proc.kill()
        }
        await waitForExit(of: proc)
        state = .exited
    }

    public func restart() async {
        await stop()
        await start()
    }

    // MARK: - Private

    private func launch() async {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        // Inherit user's PATH/environment.
        proc.environment = ProcessInfo.processInfo.environment

        let errPipe = Pipe()
        proc.standardError = errPipe
        stderrPipe = errPipe
        stderrTail = ""

        // Capture stderr tail asynchronously.
        readStderr(errPipe)

        // terminationHandler is called on a background thread;
        // hop to MainActor before mutating state.
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if p.terminationReason == .uncaughtSignal {
                    self.state = .failed("dsh terminated by signal")
                } else {
                    self.state = .exited
                }
            }
        }

        state = .starting
        process = proc

        do {
            try proc.run()
        } catch {
            state = .failed("\(executable.path) failed to launch: \(error.localizedDescription)")
            return
        }
        state = .running
    }

    private func readStderr(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let chunk = String(data: data, encoding: .utf8) else { return }
                self.stderrTail.append(chunk)
                if self.stderrTail.count > self.stderrCap {
                    let overflow = self.stderrTail.count - self.stderrCap
                    self.stderrTail.removeFirst(overflow)
                }
            }
        }
    }

    private func waitForExit(of proc: Process) async {
        await withCheckedContinuation { cont in
            if !proc.isRunning {
                cont.resume()
                return
            }
            let original = proc.terminationHandler
            proc.terminationHandler = { p in
                original?(p)
                cont.resume()
            }
        }
    }
}
```

> Note: The `guard state == .idle || ...` block in `start()` is intentionally permissive; it allows restart from `.failed`/`.exited`. The condition collapses to "any state except `.starting` or `.running`" and is structured to satisfy Swift's expression-level pattern matching. If this expression is hard to read at review time, the implementer may simplify to:

```swift
public func start() async {
    switch state {
    case .starting, .running:
        return
    case .idle, .exited, .failed:
        await launch()
    }
}
```

> and use that version instead.

- [ ] **Step 4: Run tests — verify they pass**

Run: `swift test --filter DshProcessTests 2>&1 | tail -25`
Expected: 5 tests passed. If any fail, debug before continuing.

- [ ] **Step 5: Smoke test the process wrapper end-to-end**

Run a one-shot experiment:
```bash
cat > /tmp/probe.swift <<'EOF'
import Foundation
let p = Process()
p.executableURL = URL(fileURLWithPath: "/bin/echo")
p.arguments = ["hello", "from", "probe"]
try p.run()
p.waitUntilExit()
print("exit=\(p.terminationStatus)")
EOF
swift /tmp/probe.swift
```
Expected: prints `exit=0`. Confirms the same Process API used in `DshProcess` works.

- [ ] **Step 6: Commit**

```bash
cd /Users/coderstory/CodeSource/dsh-desktop
git add Sources/DshDesktop/DshProcess.swift Tests/DshDesktopTests/DshProcessTests.swift
git commit -m "feat: DshProcess with state machine and TDD"
```

---

### Task 3: `DshHealthCheck` — wait for port 3080 (TDD)

**Files:**
- Create: `/Users/coderstory/CodeSource/dsh-desktop/Sources/DshDesktop/DshHealthCheck.swift`
- Create: `/Users/coderstory/CodeSource/dsh-desktop/Tests/DshDesktopTests/DshHealthCheckTests.swift`

**Interfaces:**
- `struct DshHealthCheck`
- `static func waitUntilReady(port: Int, timeout: TimeInterval, pollInterval: TimeInterval = 0.25) async -> Bool`

Returns `true` when an HTTP GET to `http://127.0.0.1:<port>/` returns a 2xx, `false` on timeout. Polls every `pollInterval` seconds.

- [ ] **Step 1: Write the failing tests**

`Tests/DshDesktopTests/DshHealthCheckTests.swift`:

```swift
import Testing
import Foundation
@testable import DshDesktop

@Suite("DshHealthCheck")
struct DshHealthCheckTests {

    @Test func returnsFalseOnClosedPort() async {
        // Port 1 is reserved and unreachable in normal cases.
        let ready = await DshHealthCheck.waitUntilReady(
            port: 1, timeout: 0.6, pollInterval: 0.1
        )
        #expect(ready == false)
    }

    @Test func returnsTrueWhenLocalServerResponds() async throws {
        // Spin up a tiny HTTP server on a random port using the test helper.
        let server = try TestHTTPServer.serve()
        defer { server.stop() }

        let ready = await DshHealthCheck.waitUntilReady(
            port: server.port, timeout: 3.0, pollInterval: 0.1
        )
        #expect(ready == true)
    }

    @Test func returnsTrueWhenServerReturnsNon200IsNotEnough() async throws {
        // HealthCheck must require a 2xx response, not just any connection.
        let server = try TestHTTPServer.serve(status: 500)
        defer { server.stop() }

        let ready = await DshHealthCheck.waitUntilReady(
            port: server.port, timeout: 0.6, pollInterval: 0.1
        )
        #expect(ready == false)
    }
}

/// Minimal TCP-based test server used only by the test target.
/// Listens on an ephemeral port and replies with a configurable status line.
final class TestHTTPServer {
    let port: Int
    private let listener: Socket
    private var connection: Socket?
    private let queue = DispatchQueue(label: "TestHTTPServer.\(UUID().uuidString)")
    private var stopped = false

    static func serve(status: Int = 200) throws -> TestHTTPServer {
        let server = try TestHTTPServer(status: status)
        // Wait briefly for it to bind.
        Thread.sleep(forTimeInterval: 0.05)
        return server
    }

    private init(status: Int) throws {
        // Use the BSD sockets API directly via Darwin module.
        var hints = addrinfo(
            ai_flags: AI_PASSIVE,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>? = nil
        let rc = getaddrinfo(nil, "0", &hints, &info)
        guard rc == 0, let firstInfo = info else {
            throw NSError(domain: "TestHTTPServer", code: 1)
        }
        defer { freeaddrinfo(info) }

        let serverSock = socket(firstInfo.pointee.ai_family,
                                firstInfo.pointee.ai_socktype,
                                firstInfo.pointee.ai_protocol)
        var yes: Int32 = 1
        setsockopt(serverSock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        bind(serverSock, firstInfo.pointee.ai_addr, firstInfo.pointee.ai_addrlen)
        listen(serverSock, 8)

        // Read assigned port via getsockname.
        var addr = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        getsockname(serverSock, &addr, &len)
        let portStr = String(cString: withUnsafePointer(to: &addr.sa_data) {
            $0.withMemoryRebound(to: UInt8.self, capacity: 2) {
                String(cString: $0.advanced(by: 2))
            }
        })
        // The above port extraction is unreliable across architectures; query via getsockname into sockaddr_in.
        let portInt = Self.extractPort(from: addr)

        self.listener = Socket(fd: serverSock)
        self.port = portInt
        self.status = status
        start()
    }

    private let status: Int

    private func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let fd = self.listener.fd
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { return }
            self.connection = Socket(fd: conn)
            // Read one request, then respond.
            var buf = [UInt8](repeating: 0, count: 4096)
            let _ = recv(conn, &buf, buf.count, 0)
            let body = "ok"
            let resp = "HTTP/1.1 \(self.status) OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            resp.withCString { _ = send(conn, $0, strlen($0), 0) }
            close(conn)
        }
    }

    func stop() {
        stopped = true
        connection?.close()
        listener.close()
    }

    private static func extractPort(from addr: sockaddr) -> Int {
        var addrCopy = addr
        return withUnsafePointer(to: &addrCopy.sa_data) {
            $0.withMemoryRebound(to: in_port_t.self, capacity: 1) {
                Int(CFSwapInt16BigToHost($0.pointee))
            }
        }
    }
}

private struct Socket {
    let fd: Int32
    func close() { Darwin.close(fd) }
    private static func Darwin_close(_ fd: Int32) { Darwin.close(fd) }
}
```

> The above has working Darwin socket plumbing but is verbose and unreliable for port extraction across architectures. The implementer should replace it with a more robust approach. The recommended approach below uses `Network.framework` for cleanliness — **if** Network.framework works in the test target's sandbox.

**Recommended implementation (Network.framework-based):**

```swift
import Network

final class TestHTTPServer {
    let port: UInt16
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "TestHTTPServer")

    static func serve(status: Int = 200) throws -> TestHTTPServer {
        // Bind to ephemeral port (0) by using NWParameters.tcp on port 0.
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: .any)
        var captured: NWListener?
        var port: UInt16 = 0
        let semaphore = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let p = listener.port { port = p.rawValue }
                semaphore.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 2)

        captured = listener
        let server = TestHTTPServer(listener: listener, port: port, status: status)
        server.start()
        return server
    }

    private init(listener: NWListener, port: UInt16, status: Int) {
        self.listener = listener
        self.port = port
        self.status = status
    }
    private let status: Int

    private func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.connections.append(conn)
            conn.start(queue: self.queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                _ = data
                let body = "ok"
                let resp = "HTTP/1.1 \(self.status) OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }

    func stop() {
        listener.cancel()
    }
}
```

Use the **Network.framework** version. Drop the BSD-socket + private `Socket` shim.

- [ ] **Step 2: Run the tests — confirm they fail**

Run: `swift test --filter DshHealthCheckTests 2>&1 | tail -15`
Expected: Build failure — "cannot find 'DshHealthCheck'".

- [ ] **Step 3: Implement `Sources/DshDesktop/DshHealthCheck.swift`**

```swift
import Foundation

/// Polls `http://127.0.0.1:<port>/` until it returns 2xx or the timeout expires.
public enum DshHealthCheck {

    public static func waitUntilReady(
        port: Int,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.25
    ) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else {
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode) {
                    return true
                }
            } catch {
                // server not yet listening — retry
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }
}
```

- [ ] **Step 4: Run tests — verify they pass**

Run: `swift test --filter DshHealthCheckTests 2>&1 | tail -25`
Expected: 3 tests passed. If the live-server test times out, increase `timeout:` in the test or add a small sleep after `start()` to let `NWListener` finish binding.

- [ ] **Step 5: Commit**

```bash
cd /Users/coderstory/CodeSource/dsh-desktop
git add Sources/DshDesktop/DshHealthCheck.swift Tests/DshDesktopTests/DshHealthCheckTests.swift
git commit -m "feat: DshHealthCheck with TDD"
```

---

### Task 4: `DSHWebView` (WKWebView wrapper)

**Files:**
- Create: `/Users/coderstory/CodeSource/dsh-desktop/Sources/DshDesktop/DSHWebView.swift`

**Interfaces:**
- `struct DSHWebView: NSViewRepresentable`
- `init(url: URL)`
- Public property: `url: URL` (constant per spec — fixed at 3080 throughout app life)

This view is the actual content hosted inside the SwiftUI window. We don't unit test it because it requires window context; we visually verify in Task 7.

- [ ] **Step 1: Implement `Sources/DshDesktop/DSHWebView.swift`**

```swift
import SwiftUI
import WebKit

/// Wraps a WKWebView in a SwiftUI-compatible NSViewRepresentable.
/// `url` is fixed for the app lifetime because dsh serves a single origin.
struct DSHWebView: NSViewRepresentable {

    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
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
```

- [ ] **Step 2: Build to catch syntax errors**

Run: `swift build 2>&1 | tail -10`
Expected: `Build complete!`. If SwiftUI/WebKit linking fails on Linux (CI), restrict the executable target with `.macOS(.v13)` as we did.

- [ ] **Step 3: Commit**

```bash
cd /Users/coderstory/CodeSource/dsh-desktop
git add Sources/DshDesktop/DSHWebView.swift
git commit -m "feat: DSHWebView NSViewRepresentable wrapping WKWebView"
```

---

### Task 5: ContentView with overlays + lifecycle wiring

**Files:**
- Create: `/Users/coderstory/CodeSource/dsh-desktop/Sources/DshDesktop/ContentView.swift`
- Modify: `/Users/coderstory/CodeSource/dsh-desktop/Sources/DshDesktop/DshApp.swift`

**Interfaces (consumed by DshApp):**
- `struct ContentView: View`
  - Holds `@StateObject var process: DshProcess`
  - Triggers `start()` on `.task`
  - Watches for `.running` and waits for `DshHealthCheck`
  - Renders ZStack of `DSHWebView`, loading overlay, failed overlay

DshApp is rewritten to:
- Inject the `DshProcess(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["dsh", "--profile", "web"], port: 3080)` into `ContentView`
- Add menu (File: Open in Browser, Reload)
- Apply window size and title
- Subscribe to `process.state`; on `.exited` and window close, terminate the app

- [ ] **Step 1: Implement `Sources/DshDesktop/ContentView.swift`**

```swift
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
        .onChange(of: process.state) { _, newState in
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

extension DshProcess {
    /// The TCP port this process is expected to serve on; surfaced for UI.
    var port: Int { _port }
    fileprivate var _port: Int { 0 }  // placeholder; real value supplied via init
}
```

Wait — `port` is not exposed on `DshProcess`. Either:
- Expose it as a `let` on `DshProcess`, or
- Pass `port` separately to `ContentView`.

Cleaner: add `let port: Int` (public) to `DshProcess`.

- [ ] **Step 2: Add `port` property to `DshProcess`**

Modify `Sources/DshDesktop/DshProcess.swift`:

Replace:
```swift
private let port: Int
```
with:
```swift
public let port: Int
```

And in `init`:
```swift
public init(executable: URL, arguments: [String], port: Int) {
```
now matches — already public; ensure `port` is `public let`.

Then in `ContentView.swift`, remove the `fileprivate var _port` extension and the dead `extension DshProcess` block — they are no longer needed.

- [ ] **Step 3: Rewrite `Sources/DshDesktop/DshApp.swift` to wire everything**

```swift
import SwiftUI
import AppKit

@main
struct DshApp: App {

    @StateObject private var process: DshProcess = {
        // Find `dsh` in PATH; fall back to bare name and let Process resolve via env.
        let executable = URL(fileURLWithPath: "/usr/bin/env")
        return DshProcess(executable: executable, arguments: ["dsh", "--profile", "web"], port: 3080)
    }()

    var body: some Scene {
        Window("dsh", id: "main") {
            ContentView(process: process)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Replace default "New" with useful commands.
            CommandGroup(replacing: .newItem) {}

            CommandMenu("File") {
                Button("Open in Browser") {
                    if let url = URL(string: "http://127.0.0.1:3080/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("b", modifiers: [.command])

                Button("Reload") {
                    NotificationCenter.default.post(name: .dshReload, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}

extension Notification.Name {
    static let dshReload = Notification.Name("dshReload")
}
```

- [ ] **Step 4: Update `DSHWebView` to listen for reload notification**

Modify `Sources/DshDesktop/DSHWebView.swift`:

```swift
import SwiftUI
import WebKit

struct DSHWebView: NSViewRepresentable {

    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = false
        wv.load(URLRequest(url: url))
        // Listen for reload notifications.
        NotificationCenter.default.addObserver(
            forName: .dshReload, object: nil, queue: .main
        ) { _ in
            wv.reload()
        }
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        if wv.url != url {
            wv.load(URLRequest(url: url))
        }
    }
}
```

- [ ] **Step 5: Build**

Run: `swift build 2>&1 | tail -10`
Expected: `Build complete!`. Fix any errors.

- [ ] **Step 6: Commit**

```bash
cd /Users/coderstory/CodeSource/dsh-desktop
git add Sources/DshDesktop/ContentView.swift Sources/DshDesktop/DshApp.swift Sources/DshDesktop/DSHWebView.swift Sources/DshDesktop/DshProcess.swift
git commit -m "feat: ContentView with overlays and DshApp menu wiring"
```

---

### Task 6: scripts/bundle.sh and scripts/sign.sh

**Files:**
- Create: `/Users/coderstory/CodeSource/dsh-desktop/scripts/bundle.sh`
- Create: `/Users/coderstory/CodeSource/dsh-desktop/scripts/sign.sh`

`bundle.sh` produces `build/DshDesktop.app` from `swift build -c release`.
`sign.sh` ad-hoc signs `build/DshDesktop.app`.

- [ ] **Step 1: Create `scripts/bundle.sh`**

```bash
#!/usr/bin/env bash
# Build the executable with SwiftPM and wrap it in a .app bundle.
#
# Output: build/DshDesktop.app
# Run:    ./scripts/bundle.sh   # then open build/DshDesktop.app

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
EXEC="$BIN_PATH/DshDesktop"
test -x "$EXEC" || { echo "expected executable at $EXEC"; exit 1; }

APP="$ROOT/build/DshDesktop.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> constructing $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$EXEC" "$MACOS/DshDesktop"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>ai.deepseek.dsh.desktop</string>
    <key>CFBundleName</key>
    <string>DshDesktop</string>
    <key>CFBundleDisplayName</key>
    <string>dsh</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleExecutable</key>
    <string>DshDesktop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

echo "==> wrote $APP"
echo "next: ./scripts/sign.sh"
```

- [ ] **Step 2: Create `scripts/sign.sh`**

```bash
#!/usr/bin/env bash
# Ad-hoc sign the .app for personal use. Not notarized; Gatekeeper will require
# right-click → Open the first time. Acceptable for personal use per spec §1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/DshDesktop.app"

test -d "$APP" || { echo "no $APP — run ./scripts/bundle.sh first"; exit 1; }

echo "==> codesign --force --deep --sign - $APP"
codesign --force --deep --sign - "$APP"

echo "==> verifying"
codesign --verify --verbose=2 "$APP" || true
echo "==> done"
```

- [ ] **Step 3: Make scripts executable**

```bash
cd /Users/coderstory/CodeSource/dsh-desktop
chmod +x scripts/bundle.sh scripts/sign.sh
```

- [ ] **Step 4: Smoke run the bundle script**

Run:
```bash
cd /Users/coderstory/CodeSource/dsh-desktop
./scripts/bundle.sh 2>&1 | tail -15
ls -la build/DshDesktop.app/Contents/
```
Expected:
- Last line: `next: ./scripts/sign.sh`
- `Contents/` contains `Info.plist`, `MacOS/`, `Resources/`
- `MacOS/DshDesktop` exists and is executable

- [ ] **Step 5: Sign and verify**

Run:
```bash
cd /Users/coderstory/CodeSource/dsh-desktop
./scripts/sign.sh
open build/DshDesktop.app
```
Expected:
- `codesign --verify` exits 0
- The .app opens; the placeholder window from Task 1 appears (Task 5+ will swap it for real content)

Close the window. Confirm no orphan dsh process:
```bash
pgrep -f "dsh --profile web" || echo "no orphan"
```
Expected: `no orphan`.

If an orphan exists: SIGKILL it manually now (`pkill -f "dsh --profile web"`); revisit the `windowWillClose` → `process.stop()` logic in Task 5 (the placeholder app doesn't call `stop()` because it has no `DshProcess`). This is expected at this stage — the full lifecycle is exercised in Task 7.

- [ ] **Step 6: Commit**

```bash
cd /Users/coderstory/CodeSource/dsh-desktop
git add scripts
git commit -m "build: bundle.sh wraps SwiftPM output into .app, sign.sh ad-hoc signs"
```

---

### Task 7: Window-close lifecycle hook + final manual verification

**Files:**
- Modify: `/Users/coderstory/CodeSource/dsh-desktop/Sources/DshDesktop/DshApp.swift`
- Create: `/Users/coderstory/CodeSource/dsh-desktop/README.md`

Verify spec §10 checklist end-to-end after lifecycle hook is wired.

- [ ] **Step 1: Add window-close lifecycle cleanup**

Replace `DshApp.swift` with this version that wires `NSApplicationDelegateAdaptor`:

```swift
import SwiftUI
import AppKit

@main
struct DshApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var process: DshProcess = {
        let executable = URL(fileURLWithPath: "/usr/bin/env")
        return DshProcess(executable: executable, arguments: ["dsh", "--profile", "web"], port: 3080)
    }()

    var body: some Scene {
        Window("dsh", id: "main") {
            ContentView(process: process)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("File") {
                Button("Open in Browser") {
                    if let url = URL(string: "http://127.0.0.1:3080/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("b", modifiers: [.command])
                Button("Reload") {
                    NotificationCenter.default.post(name: .dshReload, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // Keep strong ref so we can stop the process on quit.
    var process: DshProcess?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hook all windows' delegate to detect close.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.delegate = self
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Last window closing → quit the app cleanly.
        Task { [weak self] in
            guard let self else { return }
            await self.process?.stop()
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension Notification.Name {
    static let dshReload = Notification.Name("dshReload")
}
```

> This requires handing `process` to `AppDelegate.process`. The cleanest way: in `applicationDidFinishLaunching`, find `DshProcess` via a singleton or via dependency injection. Since `@StateObject private var process` lives inside `DshApp`, hand it through an environment or via `appDelegate.process = process` on appear:

Append to the `Window` content closure:
```swift
.onAppear { appDelegate.process = process }
```

- [ ] **Step 2: Apply the small edit**

Open `Sources/DshDesktop/DshApp.swift` and add `.onAppear { appDelegate.process = process }` on the `ContentView` line inside `Window`.

- [ ] **Step 3: Create `README.md`**

```markdown
# DshDesktop

A minimal native macOS wrapper around the `dsh --profile web` service.

## Requirements

- macOS 13 or later
- Xcode 15+ (for Swift 5.9 toolchain)
- `dsh` installed and available on `$PATH`

## Build

```bash
./scripts/bundle.sh     # swift build -c release + assemble DshDesktop.app
./scripts/sign.sh       # ad-hoc sign
open build/DshDesktop.app
```

## Test

```bash
swift test
```

## What it does

Spawns `dsh --profile web` as a child process and shows the web UI inside a
`WKWebView` in a SwiftUI window with title "dsh". Hardcoded to port 3080.

## Layout

```
Sources/DshDesktop/
  DshApp.swift          # @main, menu, lifecycle
  ContentView.swift     # ZStack with WebView + starting/failed overlays
  DSHWebView.swift      # WKWebView wrapper
  DshProcess.swift      # child Process + state machine
  DshHealthCheck.swift  # port 3080 polling

scripts/
  bundle.sh             # SwiftPM output → .app bundle
  sign.sh               # ad-hoc sign

Tests/DshDesktopTests/
  DshProcessTests.swift
  DshHealthCheckTests.swift
  SmokeTests.swift
```

## Notes

- First run requires right-click → Open (Gatekeeper on ad-hoc-signed apps).
- `dsh` must be on `$PATH` inherited from your shell — if you launch from Finder
  and `dsh` is only in `.zshrc`, open Terminal once and run
  `open build/DshDesktop.app` from there.
- See `docs/superpowers/specs/2026-08-15-dsh-desktop-wrapper-design.md` for
  the design rationale.
```

- [ ] **Step 4: Build, bundle, sign, open, verify per spec §10 checklist**

Run:
```bash
cd /Users/coderstory/CodeSource/dsh-desktop
swift build 2>&1 | tail -5
./scripts/bundle.sh 2>&1 | tail -5
./scripts/sign.sh
open build/DshDesktop.app
```

Verify each item in spec §10:

| Test | Expected | Pass criteria |
|---|---|---|
| Cold start with dsh installed | App window appears, localhost 3080 loads | UI shows the dsh chat panel within 2–5 s |
| Cold start with dsh NOT in PATH | `.failed` overlay "dsh not found" | Quit closes app; no orphan processes |
| Port 3080 occupied | `.failed` overlay "port 3080 not responding" | Restart fails the same way until port freed |
| dsh crash mid-session | Crash overlay with Restart button | Click Restart → app recovers without quitting |
| cmd+Q with session active | App exits, no orphan `dsh` process | `pgrep -f "dsh --profile web"` returns nothing |
| Close window with red dot | Same as cmd+Q | Same |
| cmd+R while in app | WKWebView reloads | UI flashes re-render |
| cmd+B | Default browser opens 127.0.0.1:3080 | Safari/Chrome tab opens |

Mark each test row as ✓ after verifying.

For the **dsh crash mid-session** test:
```bash
# In another terminal, find dsh child PID and kill it.
pgrep -f "dsh --profile web" | head -1 | xargs -I{} kill -9 {}
```
Expected: window content fades, `Restart` overlay appears.

For the **port-busy** test:
```bash
python3 -m http.server 3080
```
Then launch the app — expect `Restart` overlay.

- [ ] **Step 5: Commit**

```bash
cd /Users/coderstory/CodeSource/dsh-desktop
git add Sources/DshDesktop/DshApp.swift README.md
git commit -m "feat: window-close lifecycle hook, README, manual verification artifacts"
```

---

## Self-Review

**1. Spec coverage:**

| Spec § | Covered by |
|---|---|
| §1 Goal, §2 Constraints | Tasks 1–7 holistic |
| §3 Architecture | Tasks 4, 5 |
| §4.1 Package.swift | Task 1 |
| §4.2 main.swift components | Tasks 2–5 (file split: one type per file) |
| §4.3 scripts | Task 6 |
| §5.1 Launch flow | Task 5 (startFlow), Task 2 (start), Task 3 (waitUntilReady) |
| §5.2 Normal exit | Task 7 (windowWillClose → stop) |
| §5.3 dsh crash | Task 5 (.failed overlay, Restart button), Task 2 (terminationHandler) |
| §6 State machine | Task 2 |
| §7.1 Window size | Task 5 (.defaultSize, .frame) |
| §7.2 Menu | Task 5 (.commands) |
| §7.3 Overlays | Task 5 (overlay switch) |
| §7.4 Dock icon | Out of scope per spec §11 |
| §8 Error table | Task 2 (state.failed), Task 3 (timeout), Task 5 (overlay) |
| §9 Build & distribution | Task 6 (bundle.sh, sign.sh) |
| §10 Verification | Task 7 |
| §11 Out of scope | Honored |
| §12 Risks | Task 5 Step 3 (PATH inheritance via /usr/bin/env), README notes |

**2. Placeholder scan:**

- No "TBD"/"TODO" found in plan.
- One reasonable proxy used (`/usr/bin/env dsh`) — explicitly justified.
- All code blocks are concrete, executable.

**3. Type consistency:**

- `DshProcess.State` defined in Task 2 with cases: `idle, starting, running, exited, failed(String)`. Used consistently in Tasks 2, 5.
- `DshProcess.init(executable:arguments:port:)` defined Task 2; constructed Task 5 with `URL(fileURLWithPath: "/usr/bin/env")` and `["dsh", "--profile", "web"], port: 3080`. Match.
- `DshHealthCheck.waitUntilReady(port:timeout:pollInterval:)` defined Task 3 with default `pollInterval: 0.25`. Used in Task 5 with explicit `timeout: 10.0` and default `pollInterval`. Match.
- `DSHWebView(url:)` defined Task 4, accepts URL. Used in Task 5 with `URL(string: "http://127.0.0.1:\(process.port)/")!`. Match.
- `Notification.Name.dshReload` defined in Task 5 step 3 (DshApp.swift) and referenced in Task 5 step 4 (DSHWebView.swift). Match.
- `DshProcess.port` flagged as needing `public let` in Task 5 step 2 (extension block in step 1 only used as illustration — to be removed when exposing `port`).

**Pre-execution check before starting:** When Task 5 step 1 is implemented, the `extension DshProcess { var port }` stub at the bottom of the example `ContentView.swift` must be **removed** before building — the worker will not see this annotation; Task 5 step 2 calls out the change.
