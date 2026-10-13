// Port of tests/test_health.py. The poller is driven with an injected `fetch` and `sleep`: no
// network and no real time, so the tests wait on events, never on a clock. The two tests that use
// the default getter talk to a throwaway server on 127.0.0.1 (never the live gateway).
// Not ported: a callback that raises (a Swift `onState` cannot throw) and a reply without a status
// code (`fetch` returns an Int), both impossible here.
import Darwin
import Foundation
import Testing
@testable import RoboCore

/// A one-shot HTTP/1.1 server on 127.0.0.1 and a free port. The handler may stream and block;
/// each connection has its own thread. (Also used by BrainTests.)
final class LoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        var path: String
        var headers: [String: String]  // names lower-cased
    }

    struct Connection: Sendable {
        let fd: Int32
        func send(_ text: String) {
            let bytes = Array(text.utf8)
            var sent = 0
            while sent < bytes.count {
                let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if n <= 0 { return }
                sent += n
            }
        }
    }

    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var seen: [Request] = []
    var requests: [Request] { lock.withLock { seen } }

    init(_ handler: @escaping @Sendable (Request, Connection) -> Void) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) } }
        precondition(bound == 0 && listen(listener, 8) == 0, "cannot listen on loopback")
        var len = size
        withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(listener, $0, &len) } }
        port = UInt16(bigEndian: addr.sin_port)
        self.listener = listener
        Thread.detachNewThread { [self] in
            while true {
                let fd = accept(listener, nil, nil)
                if fd < 0 { return }
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread {
                    var head = Data()
                    var buf = [UInt8](repeating: 0, count: 4096)
                    while head.range(of: Data("\r\n\r\n".utf8)) == nil {
                        let n = read(fd, &buf, buf.count)
                        if n <= 0 { Darwin.close(fd); return }
                        head.append(contentsOf: buf[..<n])
                    }
                    let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        if let colon = line.firstIndex(of: ":") {
                            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        }
                    }
                    let request = Request(path: lines[0].split(separator: " ")[1].description, headers: headers)
                    self.lock.withLock { self.seen.append(request) }
                    handler(request, Connection(fd: fd))
                    Darwin.close(fd)
                }
            }
        }
    }

    func close() {
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    /// A loopback port nothing listens on.
    static func closedPort() -> UInt16 {
        let s = LoopbackServer { _, _ in }
        s.close()
        return s.port
    }
}

private enum Step: ExpressibleByIntegerLiteral {
    case status(Int)
    case fail(Error)
    init(integerLiteral status: Int) { self = .status(status) }
}

/// A `fetch` that plays a script (a status or an error per call; the last repeats) and can hold its first call.
private final class FakeFetch: @unchecked Sendable {
    private let lock = NSLock()
    private let script: [Step]
    private(set) var calls: [String] = []
    private var held: CheckedContinuation<Void, Never>?
    private var holding: Bool
    let entered: AsyncStream<Void>
    private let enteredSignal: AsyncStream<Void>.Continuation

    init(_ script: [Step], hold: Bool = false) {
        self.script = script
        holding = hold
        (entered, enteredSignal) = AsyncStream.makeStream()
    }

    var callCount: Int { lock.withLock { calls.count } }

    func callAsFunction(_ url: String) async throws -> Int {
        let n = lock.withLock { () -> Int in calls.append(url); return calls.count }
        if holding {
            enteredSignal.yield()
            await withCheckedContinuation { c in
                lock.withLock { held = c }
            }
        }
        switch script[min(n, script.count) - 1] {
        case .status(let s): return s
        case .fail(let e): throw e
        }
    }

    func release() {
        lock.withLock { holding = false; let c = held; held = nil; return c }?.resume()
    }
}

/// A clock the test drives: each `sleep` records its length, then (gated) parks until `release()`
/// or the poller cancels it, or (not gated) returns at once.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private let gated: Bool
    private var naps: [Double] = []
    private var parked: CheckedContinuation<Void, Error>?
    let entered: AsyncStream<Double>
    private let enteredSignal: AsyncStream<Double>.Continuation

    init(gated: Bool) {
        self.gated = gated
        (entered, enteredSignal) = AsyncStream.makeStream()
    }

    var seconds: [Double] { lock.withLock { naps } }

    func sleep(_ s: Double) async throws {
        lock.withLock { naps.append(s) }
        enteredSignal.yield(s)
        guard gated else { await Task.yield(); return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    c.resume(throwing: CancellationError())
                } else {
                    parked = c
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.withLock { let c = parked; parked = nil; return c }?.resume(throwing: CancellationError())
        }
    }
}

private final class StateFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var iterator: AsyncStream<HealthState>.Iterator
    private let signal: AsyncStream<HealthState>.Continuation
    private var reported = 0
    var count: Int { lock.withLock { reported } }

    init() {
        let (stream, signal) = AsyncStream<HealthState>.makeStream()
        iterator = stream.makeAsyncIterator()
        self.signal = signal
    }

    func report(_ s: HealthState) { lock.withLock { reported += 1 }; signal.yield(s) }
    func next() async -> HealthState? { await iterator.next() }
    func take(_ n: Int) async -> [HealthState] {
        var out: [HealthState] = []
        for _ in 0..<n { if let s = await next() { out.append(s) } }
        return out
    }
}

private struct Rig {
    let poller: HealthPoller
    let fetch: FakeFetch
    let clock: FakeClock
    let states: StateFeed

    /// `every` is huge, so only `retry` can explain a quick re-poll; `gated` parks every wait.
    init(_ script: [Step], url: String = "http://127.0.0.1:8642/p/robo", every: Double = 60, retry: Double = 0.01,
         gated: Bool = false, hold: Bool = false) {
        fetch = FakeFetch(script, hold: hold)
        clock = FakeClock(gated: gated)
        states = StateFeed()
        let (fetch, clock, states) = (fetch, clock, states)
        poller = HealthPoller(url: url, onState: { states.report($0) }, every: every, retry: retry,
                              fetch: { try await fetch($0) }, sleep: { try await clock.sleep($0) })
    }

    /// Start, read `n` states, stop.
    func states(_ n: Int) async -> [HealthState] {
        poller.start()
        let out = await states.take(n)
        poller.stop()
        return out
    }

    /// Wait for the poller to park in its wait, and say how long.
    func parked() async -> Double? {
        var it = clock.entered.makeAsyncIterator()
        return await it.next()
    }

    func finish() async { poller.stop(); await poller.task?.value }
}

@Suite("Health", .timeLimit(.minutes(1)))
struct HealthTests {
    @Test func okThenWaitsEveryBeforeTheNextPoll() async {
        let rig = Rig([200], gated: true)  // retry is 10 ms, every is 60 s
        rig.poller.start()
        #expect(await rig.states.next() == .ok)
        #expect(await rig.parked() == 60)
        #expect(rig.fetch.callCount == 1)
        await rig.finish()
    }

    @Test func anOkPollWaitsTheEveryIntervalNotTheRetryOne() async {
        let rig = Rig([200], every: 0.05, retry: 60)
        #expect(await rig.states(2) == [.ok, .ok])
        #expect(rig.clock.seconds.allSatisfy { $0 == 0.05 })
    }

    @Test func oneFailureIsWarnThenRetriesAfterRetryNotEvery() async {
        let rig = Rig([500, 200])
        #expect(await rig.states(2) == [.warn, .ok])  // every=60: only `retry` can explain this
        #expect(rig.clock.seconds.first == 0.01)
    }

    @Test func twoFailuresInARowAreBadAndPollingGoesOnUntilRecovery() async {
        #expect(await Rig([500, 500, 500, 200]).states(4) == [.warn, .bad, .bad, .ok])
    }

    @Test func recoveryResetsTheCount() async {
        #expect(await Rig([500, 500, 200, 500], every: 0.01).states(4) == [.warn, .bad, .ok, .warn])
    }

    @Test func pokePollsAtOnce() async {
        let rig = Rig([200], gated: true)
        rig.poller.start()
        #expect(await rig.states.next() == .ok)
        _ = await rig.parked()
        rig.poller.poke()
        #expect(await rig.states.next() == .ok)  // every=60 s, so only the poke woke it
        #expect(rig.fetch.callCount == 2)
        await rig.finish()
    }

    @Test func pokeAfterAGoodPollCanTurnItWarn() async {
        let rig = Rig([200, 500], gated: true)
        rig.poller.start()
        #expect(await rig.states.next() == .ok)
        _ = await rig.parked()
        rig.poller.poke()
        #expect(await rig.states.next() == .warn)
        await rig.finish()
    }

    /// Python's Event stays set when nobody waits: a poke during a poll shortens the next wait to nothing.
    @Test func aPokeDuringAPollSkipsTheNextWait() async {
        let rig = Rig([200, 500], gated: true, hold: true)
        rig.poller.start()
        var inside = rig.fetch.entered.makeAsyncIterator()
        _ = await inside.next()
        rig.poller.poke()
        rig.fetch.release()
        #expect(await rig.states.take(2) == [.ok, .warn])  // the gated wait is never released
        await rig.finish()
    }

    /// Python's stop() sets a flag nothing clears, so a poller stopped before start() never polls.
    @Test func stopBeforeStartSticks() async {
        let rig = Rig([200], gated: true)
        rig.poller.stop()
        rig.poller.start()
        #expect(rig.poller.task == nil)
        #expect(rig.fetch.callCount == 0 && rig.states.count == 0)
        rig.poller.stop()
    }

    /// Python raises "threads can only be started once"; a second start() here is simply ignored,
    /// so the first loop is never orphaned and stop() reaches the only one there is.
    @Test func aSecondStartIsIgnored() async {
        let rig = Rig([200], gated: true)
        rig.poller.start()
        let first = rig.poller.task
        rig.poller.start()
        #expect(rig.poller.task == first)
        #expect(await rig.states.next() == .ok)
        _ = await rig.parked()
        await rig.finish()
        #expect(rig.fetch.callCount == 1)
    }

    @Test func stopEndsTheTaskWithoutWaitingOutTheInterval() async {
        let rig = Rig([200], gated: true)
        rig.poller.start()
        #expect(await rig.states.next() == .ok)
        _ = await rig.parked()
        await rig.finish()
        #expect(rig.fetch.callCount == 1)
    }

    @Test func stopDuringTheRetryWaitEndsItAndStaysQuiet() async {
        let rig = Rig([500], retry: 60, gated: true)
        rig.poller.start()
        #expect(await rig.states.next() == .warn)
        _ = await rig.parked()
        await rig.finish()
        #expect(rig.states.count == 1)
    }

    @Test func stopDuringASlowPollReportsNothing() async {
        let rig = Rig([200], hold: true)
        rig.poller.start()
        var inside = rig.fetch.entered.makeAsyncIterator()
        _ = await inside.next()
        rig.poller.stop()
        rig.fetch.release()
        await rig.poller.task?.value
        #expect(rig.states.count == 0)  // the window is closing; nobody is listening any more
    }

    @Test(arguments: [
        ("http://127.0.0.1:8642/p/robo", "http://127.0.0.1:8642/health"),
        ("http://127.0.0.1:8642", "http://127.0.0.1:8642/health"),
        ("http://127.0.0.1:9/p/robo", "http://127.0.0.1:9/health"),  // ROBO_HERMES_URL for a red LED
    ])
    func healthURLIsTheGatewayRootPlusHealth(base: String, health: String) async {
        let rig = Rig([200], url: base)
        _ = await rig.states(1)
        #expect(rig.fetch.calls == [health])
    }

    @Test(arguments: [
        URLError(.cannotConnectToHost), URLError(.timedOut), URLError(.badURL), CocoaError(.fileNoSuchFile),
        POSIXError(.ECONNREFUSED), NSError(domain: "x", code: 1), CancellationError(),
    ] as [Error])
    func anyErrorIsAFailureAndNeverEscapes(boom: Error) async {
        #expect(await Rig([.fail(boom), .fail(boom), 200]).states(3) == [.warn, .bad, .ok])
    }

    @Test(arguments: [204, 301, 401, 404, 500, 503])
    func only200IsOk(status: Int) async {
        #expect(await Rig([.status(status)]).states(1) == [.warn])
    }

    // MARK: the default getter

    /// No headers are set, so no key can leak; a short timeout; no environment or system proxy; no cookies.
    @Test func theDefaultRequestHasNoAuthHeaderAShortTimeoutAndNoProxy() {
        let r = HealthPoller.request(URL(string: "http://127.0.0.1:8642/health")!)
        #expect(r.timeoutInterval == 1.5 && r.httpShouldHandleCookies == false)
        #expect((r.allHTTPHeaderFields ?? [:]).isEmpty)
        let config = HermesClient.makeSession().configuration
        #expect(config.connectionProxyDictionary?.isEmpty == true)
        #expect(config.httpCookieStorage == nil)
    }

    @Test func theDefaultGetterHitsHealthWithoutCredentialsAndSeesAClosedPortAsWarn() async {
        let server = LoopbackServer { request, conn in
            conn.send(request.path == "/health" ? "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                      : "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }
        defer { server.close() }
        let up = StateFeed()
        let poller = HealthPoller(url: "http://127.0.0.1:\(server.port)/p/robo", onState: { up.report($0) })
        poller.start()
        #expect(await up.next() == .ok)
        poller.stop()
        let seen = server.requests
        #expect(seen.map(\.path) == ["/health"])
        #expect(Set(seen[0].headers.keys).isDisjoint(with: ["authorization", "proxy-authorization", "cookie"]))

        let down = StateFeed()
        let dead = HealthPoller(url: "http://127.0.0.1:\(LoopbackServer.closedPort())/p/robo", onState: { down.report($0) })
        dead.start()
        #expect(await down.next() == .warn)
        dead.stop()
    }

    /// httpx does not follow redirects, so a 3xx is "not 200" and the Location is never fetched.
    @Test func aRedirectIsAnAnswerNotFollowed() async throws {
        let server = LoopbackServer { _, conn in
            conn.send("HTTP/1.1 301 Moved Permanently\r\nLocation: /health2\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }
        defer { server.close() }
        #expect(try await HealthPoller.status("http://127.0.0.1:\(server.port)/health") == 301)
        #expect(server.requests.map(\.path) == ["/health"])
    }
}
