import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Local IPC server that lets the `dsh-desktop-bridge` dsh plugin talk to
/// the wrapper. Phase 1+2: unix-domain-socket server, JSON-RPC-style
/// NDJSON protocol, connection pool with per-connection limits, graceful
/// shutdown.
///
/// Wire format
/// -----------
/// Each connection is a stream of newline-delimited JSON objects (NDJSON).
/// Either side may send a JSON-RPC-2.0-shaped message:
///
///   {"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocol":1}}
///   {"jsonrpc":"2.0","id":1,"result":true}
///   {"jsonrpc":"2.0","method":"agent/status","params":{"running":false}}
///
/// The first message on any new connection MUST be a `hello` from the
/// client; until that arrives (or 1 second elapses), the server holds the
/// connection open but does no work. Mismatched protocol version → close.
///
/// Handled RPC methods (Phase 2+):
///
///   hello     — protocol handshake (no id; treated as a hello marker)
///   notify    — show a native macOS notification
///   prefs.get — read a wrapper-persisted preference
///   prefs.set — write a wrapper-persisted preference
///
/// The wrapper also pushes server-initiated events to the client (no `id`):
///
///   onQuit    — the wrapper is about to terminate
///   onReload  — dsh was restarted; the client should reset state
///
/// All other methods return `{"error":{"code":-32601,"message":"Method not found"}}`.
///
/// **Concurrency**: DSHBridge is **not** `@MainActor`-isolated. All I/O
/// (accept, read, write) runs on `ioQueue` (a serial `DispatchQueue`).
/// Marking the class `@MainActor` would make Swift 6's strict-concurrency
/// runtime assert that the dispatch-source event handlers — which fire
/// on `ioQueue` and invoke our private methods — must run on MainActor,
/// which would `dispatch_assert_queue` trap the moment a client connects.
///
/// Handlers that genuinely need MainActor (e.g. `Notifications.notify`,
/// `Preferences.shared.*`) are `@MainActor`-annotated closures that the
/// caller can `await` from any context; the I/O thread hops to MainActor
/// only for that brief call.
public final class DSHBridge: @unchecked Sendable {

    // MARK: - Public configuration

    /// Bridge protocol version the wrapper speaks. Bumped on wire-format
    /// changes; mismatched `hello` causes the connection to close.
    public static let protocolVersion = 1

    /// Bundle ID used to compute the default socket path. Matches the
    /// wrapper's Info.plist.
    public static let bundleID = "ai.deepseek.dsh.desktop"

    /// Resolve the canonical socket path. macOS convention puts per-app
    /// mutable state under `~/Library/Application Support/<bundleID>/`.
    /// We append `bridge.sock` so it's discoverable from both sides.
    public static func defaultSocketPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home
            + "/Library/Application Support/\(bundleID)"
            + "/bridge.sock"
    }

    // MARK: - State

    private let socketPath: String
    private let maxConnections: Int
    private let maxMessageBytes: Int
    private let helloTimeout: TimeInterval

    /// Active connections, keyed by their `id` for log correlation.
    private var connections: [Int: ClientConnection] = [:]
    private var nextConnectionID: Int = 1

    /// Underlying listen socket fd. `-1` when not bound.
    private var listenFD: Int32 = -1
    /// Source for `DispatchSource.makeReadSource` on the listen socket.
    private var listenSource: DispatchSourceRead?
    /// Source for SIGTERM/SIGINT-triggered shutdown.
    private var signalSource: DispatchSourceSignal?
    /// True once `start()` succeeded.
    private var isRunning = false
    /// Set by `stop()`; once set, no new accepts.
    private var isShuttingDown = false
    /// Serial queue for all bridge I/O. Keeping the listen socket and
    /// client sockets on the same queue avoids races during shutdown.
    private let ioQueue = DispatchQueue(label: "ai.deepseek.dsh.desktop.bridge.io")

    /// Delegated notification dispatch so the bridge doesn't need to know
    /// about `UNUserNotificationCenter` directly (testability + keeps the
    /// surface area minimal). Marked `@MainActor` because the default
    /// implementation calls `Notifications.notify`, which is main-actor
    /// isolated. Tests inject a plain closure; the `MainActor` annotation
    /// is satisfied by callers from any actor by `await`-ing.
    public var notifyHandler: @MainActor (String, String) async -> Void

    /// Delegated preference access. Defaults to `Preferences.shared` but
    /// tests can inject a stub. Keys are dotted paths (e.g.
    /// "notifications.enabled"); values are arbitrary JSON-encodable
    /// scalars (bool / int / string). `@MainActor` for the same reason.
    public var prefsHandler: @MainActor (String) async -> Any?
    public var prefsSetHandler: @MainActor (String, Any) async -> Void

    // MARK: - Init

    public init(
        socketPath: String = DSHBridge.defaultSocketPath(),
        maxConnections: Int = 16,
        maxMessageBytes: Int = 1 << 20,  // 1 MiB
        helloTimeout: TimeInterval = 1.0,
        notifyHandler: @escaping @MainActor (String, String) async -> Void = { title, body in
            await Notifications.notify(title: title, body: body)
        },
        prefsHandler: @escaping @MainActor (String) async -> Any? = { key in
            switch key {
            case "notifications.enabled": return Preferences.shared.notificationsEnabled
            default: return nil
            }
        },
        prefsSetHandler: @escaping @MainActor (String, Any) async -> Void = { key, value in
            if key == "notifications.enabled", let b = value as? Bool {
                Preferences.shared.notificationsEnabled = b
            }
        }
    ) {
        self.socketPath = socketPath
        self.maxConnections = maxConnections
        self.maxMessageBytes = maxMessageBytes
        self.helloTimeout = helloTimeout
        self.notifyHandler = notifyHandler
        self.prefsHandler = prefsHandler
        self.prefsSetHandler = prefsSetHandler
    }

    // MARK: - Lifecycle

    /// Bind the listen socket and start accepting connections. Throws on
    /// I/O failure (caller may show an alert and exit). Returns once
    /// `listen()` has been called; accept loop runs on `ioQueue` until
    /// `stop()` is invoked.
    public func start() throws {
        guard !isRunning else { return }

        // Ensure the parent dir exists.
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true
        )

        // If a stale socket file exists, try connecting to it first — if
        // something answers, refuse to bind (would block the legitimate
        // owner). Otherwise unlink and continue.
        try reclaimStaleSocketFile()

        // AF_UNIX / SOCK_STREAM
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BridgeError.socketCreate(errno: errno)
        }

        // Bind.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // sun_path is fixed-size CChar; copy with explicit bound check.
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw BridgeError.socketPathTooLong(path: socketPath)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            pathBytes.withUnsafeBytes { src in
                _ = memcpy(buf.baseAddress!, src.baseAddress!, pathBytes.count)
            }
        }

        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                bind(fd, sap, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindRC != 0 {
            let err = errno
            close(fd)
            throw BridgeError.bind(errno: err, path: socketPath)
        }

        // 0600 — only this user can connect. The dsh process runs as the
        // same user, so this is fine. If dsh ever runs as a different
        // user, the bridge would need a wider perms story.
        chmod(socketPath, 0o600)

        // Listen (backlog 16 — matches the soft maxConnections limit).
        if listen(fd, 16) != 0 {
            let err = errno
            close(fd)
            unlink(socketPath)
            throw BridgeError.listen(errno: err)
        }
        listenFD = fd

        // Dispatch source for incoming connections.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.resume()
        listenSource = source

        // Signal handler for clean shutdown.
        installSignalHandlers()

        isRunning = true
        Log.bridge.notice("DSHBridge: listening on \(self.socketPath, privacy: .public) (protocol=\(Self.protocolVersion, privacy: .public))")
    }

    /// Stop accepting, drain in-flight connections, unlink the socket.
    /// Safe to call multiple times.
    public func stop() async {
        guard isRunning, !isShuttingDown else { return }
        isShuttingDown = true
        Log.bridge.notice("DSHBridge: shutting down")

        // Stop the listen source + close the listen fd so no new clients.
        listenSource?.cancel()
        listenSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }

        // Notify all connected clients that we're going away (best-effort,
        // 200 ms grace period).
        let onQuitMsg = Self.encodeLine(["method": "onQuit"])
        for conn in connections.values {
            _ = writeAll(fd: conn.write.fd, bytes: Array(onQuitMsg.utf8))
        }

        // Give the bytes time to flush.
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Tear down all client sockets.
        for conn in connections.values {
            close(conn.read.fd)
            close(conn.write.fd)
        }
        connections.removeAll()

        // Unlink the socket file so the next launch starts clean.
        unlink(socketPath)

        signalSource?.cancel()
        signalSource = nil
        isRunning = false
        isShuttingDown = false
        Log.bridge.notice("DSHBridge: shutdown complete")
    }

    // MARK: - Stale socket cleanup

    private func reclaimStaleSocketFile() throws {
        // If the socket file exists, try to connect. If that succeeds,
        // another wrapper is already serving — refuse. If connection is
        // refused (ECONNREFUSED) the file is stale and we can unlink.
        guard FileManager.default.fileExists(atPath: socketPath) else { return }

        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(probe)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            pathBytes.withUnsafeBytes { src in
                _ = memcpy(buf.baseAddress!, src.baseAddress!, pathBytes.count)
            }
        }

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                connect(probe, sap, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(probe)

        if rc == 0 {
            throw BridgeError.socketInUse(path: socketPath)
        }
        // ECONNREFUSED = stale socket. Unlink and continue.
        unlink(socketPath)
    }

    // MARK: - Accept loop

    private func acceptPending() {
        while !isShuttingDown {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                    accept(listenFD, sap, &len)
                }
            }
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                if isShuttingDown { break }
                Log.bridge.error("DSHBridge: accept failed errno=\(errno)")
                break
            }

            if connections.count >= maxConnections {
                Log.bridge.notice("DSHBridge: connection cap (\(self.maxConnections, privacy: .public)) reached — rejecting new client")
                close(clientFD)
                continue
            }

            let id = nextConnectionID
            nextConnectionID += 1
            let conn = ClientConnection(id: id, read: FDPair(fd: clientFD), write: FDPair(fd: clientFD))
            connections[id] = conn
            Log.bridge.notice("DSHBridge: client #\(id, privacy: .public) connected (\(self.connections.count, privacy: .public)/\(self.maxConnections, privacy: .public))")
            startReadLoop(for: conn)
        }
    }

    // MARK: - Per-connection read loop

    private func startReadLoop(for conn: ClientConnection) {
        // Set a 1-second hello timeout via SO_RCVTIMEO. After 1 s without
        // a valid hello, close the connection.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(conn.read.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let source = DispatchSource.makeReadSource(fileDescriptor: conn.read.fd, queue: ioQueue)
        conn.read.source = source
        source.setEventHandler { [weak self, weak conn] in
            guard let self, let conn else { return }
            self.handleReadable(conn: conn)
        }
        source.setCancelHandler { [weak self, weak conn] in
            guard let self, let conn else { return }
            self.tearDown(conn: conn)
        }
        source.resume()
    }

    private func handleReadable(conn: ClientConnection) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(conn.read.fd, &buf, buf.count, 0)
        if n <= 0 {
            // 0 = orderly close; <0 = error / timeout. In both cases we
            // tear the connection down.
            conn.read.source?.cancel()
            return
        }
        conn.read.buffer.append(contentsOf: buf[0..<n])
        if conn.read.buffer.count > maxMessageBytes {
            Log.bridge.error("DSHBridge: client #\(conn.id, privacy: .public) exceeded \(self.maxMessageBytes, privacy: .public) bytes — closing")
            conn.read.source?.cancel()
            return
        }
        // Split on '\n', process complete lines, keep the trailing partial.
        while let nl = conn.read.buffer.firstIndex(of: 0x0a) {
            let lineBytes = Array(conn.read.buffer[0..<nl])
            conn.read.buffer.removeSubrange(0...nl)
            guard let line = String(bytes: lineBytes, encoding: .utf8), !line.isEmpty else { continue }
            processLine(line, on: conn)
        }
    }

    /// Parse one NDJSON line and dispatch. Runs on `ioQueue`.
    private func processLine(_ line: String, on conn: ClientConnection) {
        guard let data = line.data(using: .utf8) else {
            sendError(to: conn, id: nil, code: -32700, message: "Parse error")
            return
        }
        // Use a manual JSON shape pull rather than JSONSerialization.jsonObject
        // because the latter traps / returns nil under Swift 6 strict
        // concurrency when invoked from a nonisolated context with a [String:Any]
        // outparam. The shapes we receive are tiny (3-5 keys), so we just
        // walk the bytes directly.
        guard let obj = Self.parseJSONObject(data) else {
            sendError(to: conn, id: nil, code: -32700, message: "Parse error")
            return
        }
        let method = obj["method"] as? String
        let id = obj["id"] as? Int
        let params = obj["params"] as? [String: Any] ?? [:]

        // First message must be `hello`. Until we see it (or timeout) we
        // don't dispatch any other method.
        if !conn.helloReceived {
            if method == "hello" {
                let clientProtocol = (params["protocol"] as? Int) ?? -1
                if clientProtocol != Self.protocolVersion {
                    Log.bridge.notice("DSHBridge: client #\(conn.id, privacy: .public) sent hello with protocol=\(clientProtocol, privacy: .public) — closing")
                    sendError(to: conn, id: id, code: -32600, message: "Protocol mismatch: wrapper speaks \(Self.protocolVersion)")
                    conn.read.source?.cancel()
                    return
                }
                conn.helloReceived = true
                sendResult(to: conn, id: id, result: [
                    "protocol": Self.protocolVersion,
                    "server": "DshDesktop",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                ])
                Log.bridge.notice("DSHBridge: client #\(conn.id, privacy: .public) hello ok (protocol=\(clientProtocol, privacy: .public))")
                return
            } else {
                // Pre-hello method calls are not allowed.
                sendError(to: conn, id: id, code: -42600, message: "Send `hello` first")
                return
            }
        }

        // Real dispatch.
        switch method {
        case "notify":
            let title = (params["title"] as? String) ?? ""
            let body = (params["body"] as? String) ?? ""
            Task { @MainActor [notifyHandler] in
                await notifyHandler(title, body)
            }
            sendResult(to: conn, id: id, result: true)

        case "prefs.get":
            let key = (params["key"] as? String) ?? ""
            Task { @MainActor [prefsHandler, weak conn] in
                let value = await prefsHandler(key)
                guard let conn else { return }
                self.sendResult(to: conn, id: id, result: ["value": value as Any? ?? NSNull()])
            }

        case "prefs.set":
            let key = (params["key"] as? String) ?? ""
            let value = params["value"] as Any? ?? NSNull()
            Task { @MainActor [prefsSetHandler, weak conn] in
                await prefsSetHandler(key, value)
                guard let conn else { return }
                self.sendResult(to: conn, id: id, result: true)
            }

        case "goodbye":
            // Client is closing cleanly.
            sendResult(to: conn, id: id, result: true)
            conn.read.source?.cancel()
            return

        case nil:
            sendError(to: conn, id: id, code: -32600, message: "Missing method")

        default:
            sendError(to: conn, id: id, code: -32601, message: "Method not found: \(method ?? "")")
        }
    }

    // MARK: - Wire helpers

    private func sendResult(to conn: ClientConnection, id: Int?, result: Any) {
        var envelope: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { envelope["id"] = id }
        let line = Self.encodeLine(envelope)
        _ = writeAll(fd: conn.write.fd, bytes: Array(line.utf8))
    }

    private func sendError(to conn: ClientConnection, id: Int?, code: Int, message: String) {
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        if let id { envelope["id"] = id }
        let line = Self.encodeLine(envelope)
        _ = writeAll(fd: conn.write.fd, bytes: Array(line.utf8))
    }

    private func tearDown(conn: ClientConnection) {
        Log.bridge.notice("DSHBridge: client #\(conn.id, privacy: .public) disconnected")
        // read+write share fd for stream sockets; close once.
        close(conn.read.fd)
        connections.removeValue(forKey: conn.id)
    }

    // MARK: - Minimal JSON parser

    /// Parse a tiny JSON object literal (one level deep, with primitive
    /// scalar values: string / int / bool / null). Returns `nil` on
    /// malformed input. We avoid `JSONSerialization.jsonObject(...)`
    /// because under Swift 6 strict-concurrency, calling it from a
    /// nonisolated context (this file's read loop runs on `ioQueue`)
    /// with a `[String: Any]` outparam either traps or returns nil
    /// depending on the SDK's strict-concurrency diagnostics level.
    ///
    /// Recognised shape (the only shape the wrapper / plugin emit):
    ///
    ///   {"key":"string","key2":42,"key3":true,"key4":null,
    ///    "key5":{"nested":"obj"},"key6":[1,2,3]}
    fileprivate static func parseJSONObject(_ data: Data) -> [String: Any]? {
        var idx = 0
        func skipWS() { while idx < data.count, data[idx] == 0x20 || data[idx] == 0x09 || data[idx] == 0x0a || data[idx] == 0x0d { idx += 1 } }
        func expect(_ b: UInt8) -> Bool {
            skipWS()
            guard idx < data.count, data[idx] == b else { return false }
            idx += 1
            return true
        }
        func readString() -> String? {
            guard expect(0x22) else { return nil }  // "
            let start = idx
            while idx < data.count, data[idx] != 0x22 {
                if data[idx] == 0x5c, idx + 1 < data.count {  // backslash escape
                    idx += 2
                } else {
                    idx += 1
                }
            }
            guard idx < data.count else { return nil }
            let s = String(data: data[start..<idx], encoding: .utf8) ?? ""
            idx += 1  // closing "
            return s
        }
        func readValue() -> Any? {
            skipWS()
            guard idx < data.count else { return nil }
            let c = data[idx]
            if c == 0x22 { return readString() }
            if c == 0x7b { idx += 1; return readObject() }
            if c == 0x5b { return readArray() }
            if c == 0x74 { idx += 4; return true }   // true
            if c == 0x66 { idx += 5; return false }  // false
            if c == 0x6e { idx += 4; return NSNull() }  // null
            // number — read up to delimiter
            let start = idx
            while idx < data.count {
                let cc = data[idx]
                if cc == 0x2c || cc == 0x7d || cc == 0x5d || cc == 0x20 || cc == 0x0a || cc == 0x0d || cc == 0x09 { break }
                idx += 1
            }
            let s = String(data: data[start..<idx], encoding: .utf8) ?? ""
            return Int(s) ?? Double(s) ?? s
        }
        func readObject() -> [String: Any]? {
            // Caller has already consumed the opening `{`.
            var dict: [String: Any] = [:]
            skipWS()
            if idx < data.count, data[idx] == 0x7d { idx += 1; return dict }  // }
            while true {
                skipWS()
                guard let key = readString() else { return nil }
                guard expect(0x3a) else { return nil }  // :
                guard let v = readValue() else { return nil }
                dict[key] = v
                skipWS()
                guard idx < data.count else { return nil }
                if data[idx] == 0x2c { idx += 1; continue }  // ,
                if data[idx] == 0x7d { idx += 1; return dict }  // }
                return nil
            }
        }
        func readArray() -> [Any]? {
            guard expect(0x5b) else { return nil }  // [
            var arr: [Any] = []
            skipWS()
            if idx < data.count, data[idx] == 0x5d { idx += 1; return arr }
            while true {
                guard let v = readValue() else { return nil }
                arr.append(v)
                skipWS()
                guard idx < data.count else { return nil }
                if data[idx] == 0x2c { idx += 1; continue }
                if data[idx] == 0x5d { idx += 1; return arr }
                return nil
            }
        }
        guard expect(0x7b) else { return nil }
        return readObject()
    }

    // MARK: - Static helpers

    /// Encode a JSON-serialisable value as one NDJSON line (no trailing
    /// newline; the caller appends one).
    ///
    /// Hand-rolled to avoid `JSONSerialization.data(withJSONObject:)`,
    /// which under Swift 6 strict-concurrency in nonisolated contexts
    /// either traps or returns nil. We only emit shapes we control, so
    /// a deterministic encoder is fine.
    private static func encodeLine(_ obj: Any) -> String {
        return encodeJSONValue(obj) + "\n"
    }

    private static func encodeJSONValue(_ v: Any) -> String {
        if let s = v as? String { return encodeJSONString(s) }
        if let i = v as? Int { return String(i) }
        if let b = v as? Bool { return b ? "true" : "false" }
        if v is NSNull { return "null" }
        if let d = v as? [String: Any] { return encodeJSONObject(d) }
        if let a = v as? [Any] {
            let inner = a.map { encodeJSONValue($0) }.joined(separator: ",")
            return "[" + inner + "]"
        }
        return "null"
    }

    private static func encodeJSONObject(_ dict: [String: Any]) -> String {
        // We don't sort keys — the protocol is server-defined, the
        // client parses the result; sorting here doesn't help.
        let parts = dict.map { (k, v) in "\(encodeJSONString(k)):\(encodeJSONValue(v))" }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private static func encodeJSONString(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        out += "\""
        return out
    }

    /// Best-effort write of all bytes to a non-blocking fd. Returns the
    /// number of bytes written; 0 / partial writes are logged but not
    /// fatal — the caller's per-connection source will redrive.
    private func writeAll(fd: Int32, bytes: [UInt8]) -> Int {
        var written = 0
        while written < bytes.count {
            let n = send(fd, Array(bytes[written...]), bytes.count - written, 0)
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    // Buffer full — drop. For now the protocol is small
                    // enough that 4 KiB send buffer overflow is unlikely
                    // in practice; if it becomes an issue, switch to
                    // per-connection outbound queues.
                    Log.bridge.error("DSHBridge: send would block (draining = bytes)")
                    return written
                }
                Log.bridge.error("DSHBridge: send failed errno=\(errno)")
                return written
            }
            if n == 0 { break }
            written += n
        }
        return written
    }

    private func installSignalHandlers() {
        // We deliberately do NOT override SIGINT/SIGTERM here — those
        // belong to the SwiftUI app lifecycle (NSApp.terminate). What we
        // *do* care about is internal pipe-close events; for that the
        // listen source + accept loop handle the common cases.
        //
        // Kept as a no-op anchor for future signal-driven paths.
        signalSource = nil
    }

    // MARK: - Errors

    public enum BridgeError: Error, CustomStringConvertible {
        case socketCreate(errno: Int32)
        case socketPathTooLong(path: String)
        case bind(errno: Int32, path: String)
        case listen(errno: Int32)
        case socketInUse(path: String)

        public var description: String {
            switch self {
            case .socketCreate(let e): return "DSHBridge: socket() failed errno=\(e)"
            case .socketPathTooLong(let p): return "DSHBridge: socket path '\(p)' exceeds sockaddr_un.sun_path"
            case .bind(let e, let p): return "DSHBridge: bind(\(p)) failed errno=\(e)"
            case .listen(let e): return "DSHBridge: listen() failed errno=\(e)"
            case .socketInUse(let p): return "DSHBridge: socket '\(p)' already in use by another wrapper instance"
            }
        }
    }
}

// MARK: - Connection bookkeeping

/// One accepted client. The socket is full-duplex so we hold two FDPair
/// views over the same fd (one for reading, one for writing) to keep
/// buffer state isolated. Reference type so we can `weak conn` capture
/// it inside dispatch handlers (struct values can't be weak-referenced).
///
/// `@unchecked Sendable` because all mutations happen on `ioQueue` and
/// the only cross-actor exposure is via `[weak conn]` capture inside a
/// `Task { @MainActor ... }` — and `conn` is only USED inside that
/// closure under `guard let conn else { return }`, so the runtime race
/// (conn torn down between check and use) is benign (we silently drop
/// the response on a closing connection).
private final class ClientConnection: @unchecked Sendable {
    let id: Int
    let read: FDPair
    let write: FDPair
    var helloReceived: Bool = false

    init(id: Int, read: FDPair, write: FDPair) {
        self.id = id
        self.read = read
        self.write = write
        self.helloReceived = false
    }
}

/// Wrapper around a file descriptor with per-direction buffer + dispatch
/// source. The `source` is only set on the read side; the write side is
/// driven synchronously from `sendResult` / `sendError`.
private final class FDPair {
    let fd: Int32
    var buffer: [UInt8] = []
    var source: DispatchSourceRead?
    init(fd: Int32) {
        self.fd = fd
    }
}