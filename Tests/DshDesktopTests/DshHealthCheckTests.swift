import Testing
import Foundation
import Network
import Darwin
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
            port: Int(server.port), timeout: 3.0, pollInterval: 0.1
        )
        #expect(ready == true)
    }

    @Test func returnsTrueWhenServerReturnsNon200IsNotEnough() async throws {
        // HealthCheck must require a 2xx response, not just any connection.
        let server = try TestHTTPServer.serve(status: 500)
        defer { server.stop() }

        let ready = await DshHealthCheck.waitUntilReady(
            port: Int(server.port), timeout: 0.6, pollInterval: 0.1
        )
        #expect(ready == false)
    }
}

/// Minimal HTTP test server used only by the test target.
/// Binds an ephemeral port via Network.framework and replies with a configurable status.
final class TestHTTPServer {
    let port: UInt16
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private let queue: DispatchQueue

    static func serve(status: Int = 200) throws -> TestHTTPServer {
        // Find a free port via BSD sockets (NWListener(using:on:) does not
        // accept port 0 for kernel-assigned ephemeral binding on macOS).
        let freePort = Self.findFreePort()
        guard freePort > 0, let endpoint = NWEndpoint.Port(rawValue: freePort) else {
            throw NSError(domain: "TestHTTPServer", code: 1)
        }
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: endpoint)
        let queue = DispatchQueue(label: "TestHTTPServer")
        let semaphore = DispatchSemaphore(value: 0)

        let port = UInt16(endpoint.rawValue)
        let server = TestHTTPServer(listener: listener, port: port, status: status, queue: queue)
        // Wire newConnectionHandler BEFORE start() so it is in place when
        // incoming connections arrive.
        server.start()

        listener.stateUpdateHandler = { state in
            if case .ready = state { semaphore.signal() }
        }
        listener.start(queue: queue)
        let didSignal = semaphore.wait(timeout: .now() + 2) == .success
        guard didSignal else {
            throw NSError(domain: "TestHTTPServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "NWListener did not reach .ready within 2s"])
        }

        // Small grace period to let NWListener finish any post-ready setup.
        Thread.sleep(forTimeInterval: 0.05)
        return server
    }

    /// Uses BSD sockets only to discover an ephemeral free port; the actual
    /// HTTP server is driven by Network.framework above.
    private static func findFreePort() -> UInt16 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return 0 }
        defer { Darwin.close(s) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        var a = addr
        let bindResult = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return 0 }
        listen(s, 1)
        var outAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &outAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(s, sa, &len)
            }
        }
        return UInt16(bigEndian: outAddr.sin_port)
    }

    private init(listener: NWListener, port: UInt16, status: Int, queue: DispatchQueue) {
        self.listener = listener
        self.port = port
        self.status = status
        self.queue = queue
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
