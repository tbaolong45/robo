// Port of tests/test_brain.py. httpx.MockTransport becomes a URLProtocol stub (no real network);
// the one test that needs a real socket (events arrive while the connection is still open) talks to
// a throwaway server on 127.0.0.1, never the live gateway.
// Not ported: "approve refuses unknown choices" (ApprovalChoice has no such case, so it cannot be
// called) and the proxy-in-the-environment half of the real-server test (URLSession ignores the
// environment; the session is built with no proxy at all, which is asserted instead).
import Foundation
import Testing
@testable import RoboCore

private let KEY = "sekret-key"

/// What the stub saw of one request.
private struct Seen {
    var method: String
    var url: String
    var path: String
    var headers: [String: String]
    var body: Data
    var lastEventID: String? { headers["Last-Event-ID"] }
    var json: [String: String]? { try? JSONSerialization.jsonObject(with: body) as? [String: String] }
}

/// What the stub answers: a status and body chunks (delivered one by one), or a failure.
private struct Reply {
    var status = 200
    var chunks: [Data] = []
    var failure: URLError.Code?

    static func sse(_ chunks: Data...) -> Reply { Reply(chunks: chunks) }
    static func sse(chunks: [Data]) -> Reply { Reply(chunks: chunks) }
    static func json(_ status: Int, _ object: Any) -> Reply {
        Reply(status: status, chunks: [try! JSONSerialization.data(withJSONObject: object)])
    }
    static func fail(_ code: URLError.Code) -> Reply { Reply(failure: code) }
}

/// Answers every request of a session built with `protocolClasses = [StubProtocol.self]`. The
/// handler is global, so the suite runs serialized.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((Seen) -> Reply)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while case let n = stream.read(&buf, maxLength: buf.count), n > 0 { body.append(contentsOf: buf[..<n]) }
            stream.close()
        }
        let url = request.url!
        let seen = Seen(method: request.httpMethod ?? "GET", url: url.absoluteString, path: url.path,
                        headers: request.allHTTPHeaderFields ?? [:], body: body)
        let reply = Self.handler!(seen)
        if let code = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func client(base: String = "http://h:8642", _ handler: @escaping (Seen) -> Reply) -> HermesClient {
    StubProtocol.handler = handler
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return HermesClient(baseURL: base, key: KEY, session: URLSession(configuration: config))
}

private final class Log<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

private func frame(_ seq: Int, _ name: String, _ fields: [String: Any] = [:]) -> Data {
    let data: [String: Any] = ["event": name, "run_id": "r1", "timestamp": 1.0, "seq": seq].merging(fields) { $1 }
    return Data("id: \(seq)\ndata: ".utf8) + (try! JSONSerialization.data(withJSONObject: data)) + Data("\n\n".utf8)
}

private let FULL: Data = {
    let approval: [String: Any] = ["command": "rm -rf /tmp/x", "description": "recursive delete", "choices": ["once", "deny"],
                                   "request_id": "q1"]
    let frames: [Data] = [
        Data(": open\n\n".utf8),
        frame(0, "message.delta", ["delta": "[[feel:happy]] Hel"]),
        frame(1, "reasoning.available", ["text": "hmm"]),  // post-hoc copy of the reply: ignored
        frame(2, "tool.started", ["tool": "web_search", "preview": "robots"]),
        frame(3, "tool.completed", ["tool": "web_search", "duration": 1.5, "error": false]),
        frame(4, "message.interim", ["text": "x", "already_streamed": true]),
        frame(5, "subagent.spawned", ["agent": "kid"]),
        frame(6, "approval.request", approval),
        frame(7, "message.delta", ["delta": "lo"]),
        frame(8, "run.completed", ["output": "[[feel:happy]] Hello", "completed": true]),
        Data(": stream closed\n\n".utf8),
    ]
    return frames.reduce(Data(), +)
}()

private func pieces(_ data: Data, by n: Int) -> [Data] {
    stride(from: 0, to: data.count, by: n).map { data[$0..<min($0 + n, data.count)] }
}

private func collect(_ s: AsyncThrowingStream<Event, Error>) async throws -> [Event] {
    var out: [Event] = []
    for try await e in s { out.append(e) }
    return out
}

private func failedMessage(_ events: [Event]) -> String? {
    if case .runEnded("failed", _, let error)? = events.last { error } else { nil }
}

@Suite("Brain", .serialized, .timeLimit(.minutes(1)))
struct BrainTests {
    @Test func eventsParsesSplitFrames() async throws {
        let events = try await collect(client { _ in .sse(chunks: pieces(FULL, by: 7)) }.events("r1"))
        #expect(events == [
            .delta("[[feel:happy]] Hel"), .toolStarted("web_search"), .toolCompleted(tool: "web_search", error: false),
            .approvalNeeded("recursive delete: rm -rf /tmp/x", id: "q1"), .delta("lo"),
            .runEnded(status: "completed", output: "[[feel:happy]] Hello"),
        ])
    }

    @Test(arguments: [
        ("run.failed", ["error": "boom"], Event.runEnded(status: "failed", error: "boom")),
        ("run.cancelled", ["completed": false], .runEnded(status: "cancelled")),
        ("run.interrupted", ["error": "shutdown"], .runEnded(status: "interrupted", error: "shutdown")),
    ] as [(String, [String: Any], Event)])
    func terminalEvents(name: String, fields: [String: Any], want: Event) async throws {
        #expect(try await collect(client { _ in .sse(frame(0, name, fields)) }.events("r1")) == [want])
    }

    @Test func stopsReadingAfterTerminalEvent() async throws {
        let body = frame(0, "run.completed", ["output": "a"]) + frame(1, "message.delta", ["delta": "late"])
        #expect(try await collect(client { _ in .sse(body) }.events("r1")) == [.runEnded(status: "completed", output: "a")])
    }

    // Hermes' run.completed: usage {input_tokens, output_tokens, total_tokens, cache_read_tokens, cache_write_tokens} and
    // runtime {provider, model} (gateway/platforms/api_server_runs.py `_USAGE_FIELDS`, `_sanitize_runtime_metadata`).
    private static let usage: [String: Any] = ["input_tokens": 1200, "output_tokens": 340, "total_tokens": 1540, "cache_read_tokens": 9000,
                                               "cache_write_tokens": 15]
    private static let runtime: [String: Any] = ["provider": "anthropic", "model": "claude-opus-4-5", "route_source": "global"]
    private static let record = UsageRecord(model: "claude-opus-4-5", input: 1200, output: 340, total: 1540, cacheRead: 9000, cacheWrite: 15)

    @Test func aCompletedRunReportsItsUsageJustBeforeItsEnd() async throws {
        let body = frame(0, "message.delta", ["delta": "hi"]) + frame(1, "run.completed", ["output": "hi", "usage": Self.usage, "runtime": Self.runtime])
        #expect(try await collect(client { _ in .sse(body) }.events("r1")) == [
            .delta("hi"), .usage(Self.record), .runEnded(status: "completed", output: "hi"),
        ])
    }

    @Test func usageSurvivesAskInOrder() async throws {
        let c = client { req in
            req.method == "POST" ? .json(202, ["run_id": "r1"]) : .sse(frame(0, "message.delta", ["delta": "[[feel:happy]]Hi"]),
                                                                       frame(1, "run.completed", ["output": "Hi", "usage": Self.usage, "runtime": Self.runtime]))
        }
        #expect(try await collect(c.ask("hi", sessionId: "s")) == [
            .feeling("happy"), .delta("Hi"), .usage(Self.record), .runEnded(status: "completed", output: "Hi"),
        ])
    }

    @Test func usageIsReadFromWhatHermesSendsAndOnlyOnACompletedRun() {
        #expect(HermesClient.usage(["event": "run.completed", "usage": Self.usage]) == UsageRecord(
            model: "", input: 1200, output: 340, total: 1540, cacheRead: 9000, cacheWrite: 15))  // no runtime: no model
        #expect(HermesClient.usage(["event": "run.completed", "usage": ["input_tokens": 10, "output_tokens": 5]]) == UsageRecord(
            input: 10, output: 5, total: 15))  // no total: input and output
        #expect(HermesClient.usage(["event": "run.completed"]) == nil && HermesClient.usage(["event": "run.completed", "usage": [:]]) == nil)
        for name in ["run.failed", "run.cancelled", "run.interrupted", "message.delta"] {  // none counts a run that did not complete
            #expect(HermesClient.usage(["event": name, "usage": Self.usage]) == nil)
        }
    }

    @Test func aRunWithoutUsageEndsWithoutAUsageEvent() async throws {
        let body = frame(0, "run.completed", ["output": "hi", "usage": [:]])
        #expect(try await collect(client { _ in .sse(body) }.events("r1")) == [.runEnded(status: "completed", output: "hi")])
        let failed = frame(0, "run.failed", ["error": "boom", "usage": Self.usage])
        #expect(try await collect(client { _ in .sse(failed) }.events("r1")) == [.runEnded(status: "failed", error: "boom")])
    }

    @Test func lostStreamResumesOnceFromLastEventId() async throws {
        let seen = Log<String?>()
        let c = client { req in
            seen.add(req.lastEventID)
            if seen.all.count == 1 {  // the connection drops mid-frame
                return .sse(frame(0, "message.delta", ["delta": "hi"]), Data(#"data: {"ev"#.utf8))
            }
            return .sse(frame(1, "run.completed", ["output": "hi"]))
        }
        #expect(try await collect(c.events("r1")) == [.delta("hi"), .runEnded(status: "completed", output: "hi")])
        #expect(seen.all == [nil, "0"])
    }

    @Test func lostTwiceStopsTheRunAndFails() async throws {
        struct Call: Equatable { var method: String; var path: String; var lastEventID: String? }
        let calls = Log<Call>()
        let c = client { req in
            calls.add(Call(method: req.method, path: req.path, lastEventID: req.lastEventID))
            if req.method == "POST" { return .json(200, [String: String]()) }
            return .sse(frame(calls.all.count - 1, "message.delta", ["delta": "x"]), Data("data: {".utf8))
        }
        let events = try await collect(c.events("r1"))
        #expect(events.filter { if case .delta = $0 { true } else { false } } == [.delta("x"), .delta("x")])
        #expect(failedMessage(events)?.isEmpty == false)
        #expect(calls.all == [Call(method: "GET", path: "/v1/runs/r1/events", lastEventID: nil),
                              Call(method: "GET", path: "/v1/runs/r1/events", lastEventID: "0"),
                              Call(method: "POST", path: "/v1/runs/r1/stop", lastEventID: nil)])
    }

    @Test func connectionErrorEndsFailed() async throws {
        let events = try await collect(client { _ in .fail(.cannotConnectToHost) }.events("r1"))
        #expect(events.count == 1)
        let error = failedMessage(events) ?? ""
        #expect(error.contains("not running") && error.contains("`hermes gateway start`"))
    }

    @Test func httpErrorOnStreamEndsFailed() async throws {
        let events = try await collect(client { _ in .json(404, ["error": ["message": "gone"]]) }.events("r1"))
        #expect(events == [.runEnded(status: "failed", error: "Hermes error 404: gone")])
    }

    @Test func aRejectedKeyOnTheStreamEndsFailedAndReadable() async throws {
        let events = try await collect(client { _ in .json(401, ["error": ["message": "Invalid API key"]]) }.events("r1"))
        #expect(events.count == 1)
        #expect(failedMessage(events)?.contains("`robo setup`") == true)
    }

    /// A frame that is not JSON is retried like a dropped stream; the id of the frame that failed to parse is not remembered.
    @Test func malformedDataIsRetriedFromTheLastGoodId() async throws {
        let seen = Log<String?>()
        let c = client { req in
            seen.add(req.lastEventID)
            return seen.all.count == 1 ? .sse(Data("id: 7\ndata: not json\n\n".utf8)) : .sse(frame(1, "run.completed"))
        }
        #expect(try await collect(c.events("r1")) == [.runEnded(status: "completed")])
        #expect(seen.all == [nil, nil])

        let twice = try await collect(client { _ in .sse(Data("data: [1]\n\n".utf8)) }.events("r1"))
        #expect(failedMessage(twice) == "Hermes sent malformed data")
    }

    /// SSE allows \r\n and a lone \r as line ends; ids may carry spaces.
    @Test func lineEndingsAreAnySseNewline() async throws {
        let crlf = Data("id:  3 \r\ndata: {\"event\": \"message.delta\",\r\ndata: \"delta\": \"a\"}\r\n\r\n".utf8)
        let cr = Data("data:{\"event\":\"run.completed\",\"output\":\"b\"}\r\r".utf8)
        let seen = Log<String?>()
        let c = client { req in
            seen.add(req.lastEventID)
            return seen.all.count == 1 ? .sse(chunks: pieces(crlf, by: 1)) : .sse(chunks: pieces(cr, by: 1))
        }
        // the first stream ends without a result, so the second is asked to resume after id 3
        #expect(try await collect(c.events("r1")) == [.delta("a"), .runEnded(status: "completed", output: "b")])
        #expect(seen.all == [nil, "3"])
    }

    @Test func startRunRequestAndPrefixJoin() async throws {
        let seen = Log<Seen>()
        let c = client(base: "http://127.0.0.1:8642/p/robo/") { req in
            seen.add(req)
            return .json(202, ["run_id": "run_9", "status": "started"])
        }
        #expect(try await c.startRun("hi", sessionId: "s1") == "run_9")
        let req = try #require(seen.all.first)
        #expect(req.method == "POST" && req.url == "http://127.0.0.1:8642/p/robo/v1/runs")
        #expect(req.headers["Authorization"] == "Bearer \(KEY)")
        #expect(req.json == ["input": "hi", "session_id": "s1"])
    }

    @Test func a401IsReadableAndHidesTheKey() async {
        let c = client { _ in .json(401, ["error": ["message": "Invalid API key"]]) }
        do {
            _ = try await c.startRun("hi", sessionId: "s1")
            Issue.record("expected a BrainError")
        } catch {
            let message = "\(error)"
            #expect(message.lowercased().contains("key") && !message.contains(KEY))
            #expect(message.contains("`robo setup`"))  // the fix for a key Hermes no longer knows
        }
    }

    @Test func aPlainErrorBodyFallsBackToTheReasonPhrase() async {
        for body in [Reply(status: 500, chunks: [Data("oops".utf8)]), .json(500, ["error": "not an object"])] {
            do {
                try await client { _ in body }.stop("r1")
                Issue.record("expected a BrainError")
            } catch {
                #expect("\(error)" == "Hermes error 500: Internal Server Error")
            }
        }
    }

    @Test func connectionRefusedSaysNotRunning() async {
        do {
            try await client { _ in .fail(.cannotConnectToHost) }.stop("r1")
            Issue.record("expected a BrainError")
        } catch let e as BrainError {
            #expect(e.message.contains("not running") && e.message.contains("`hermes gateway start`"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test(arguments: [ApprovalChoice.once, .session, .deny])
    func approveAndStopBodies(choice: ApprovalChoice) async throws {
        let seen = Log<Seen>()
        let c = client(base: "http://h/p") { req in seen.add(req); return .json(200, [String: String]()) }
        try await c.approve("r1", choice)
        try await c.stop("r1")
        let (approve, stop) = (seen.all[0], seen.all[1])
        #expect(approve.url == "http://h/p/v1/runs/r1/approval" && approve.json == ["choice": choice.rawValue])  // no id: Hermes answers the oldest
        #expect(stop.method == "POST" && stop.url == "http://h/p/v1/runs/r1/stop")
    }

    /// Two asks can be pending at once and Hermes answers the oldest unless told which: the answer names its request.
    @Test(arguments: [ApprovalChoice.once, .session, .deny])
    func approveNamesTheRequestItAnswers(choice: ApprovalChoice) async throws {
        let seen = Log<Seen>()
        let c = client(base: "http://h/p") { req in seen.add(req); return .json(200, [String: String]()) }
        try await c.approve("r1", choice, requestId: "9f2c")
        #expect(seen.all[0].url == "http://h/p/v1/runs/r1/approval")
        #expect(seen.all[0].json == ["choice": choice.rawValue, "request_id": "9f2c"])
    }

    @Test func approvalHasNoAlways() {
        #expect(ApprovalChoice(rawValue: "always") == nil)  // robo never grants a permanent approval
    }

    @Test func askSplitsFeelingsAndStripsOutput() async throws {
        let c = client { req in
            req.method == "POST" ? .json(202, ["run_id": "r1", "status": "started"]) : .sse(chunks: pieces(FULL, by: 5))
        }
        let started = Log<String>()
        let events = try await collect(c.ask("hi", sessionId: "s1", started: { started.add($0) }))
        #expect(started.all == ["r1"])
        #expect(events[0] == .feeling("happy"))
        #expect(events.reduce("") { if case .delta(let t) = $1 { $0 + t } else { $0 } } == "Hello")
        #expect(events.last == .runEnded(status: "completed", output: "Hello"))
        #expect(events.filter { if case .runEnded = $0 { true } else { false } }.count == 1)
    }

    /// The client keeps no per-run state, so one client serves any number of runs at once: each ask
    /// gets its own run id and only its own events. (Python's `run_id` attribute is gone; the window tracks it.)
    @Test func manyAsksAtOnceOnOneClientKeepTheirRunsApart() async throws {
        let c = client { req in
            if req.method == "POST" { return .json(202, ["run_id": "r-\(req.json?["input"] ?? "")"]) }
            let id = req.path.split(separator: "/")[2]
            return .sse(frame(0, "message.delta", ["delta": "[[feel:happy]]\(id)"]), frame(1, "run.completed", ["output": "\(id)"]))
        }
        let runs = try await withThrowingTaskGroup(of: (Int, String, [Event]).self) { group in
            for i in 0..<8 {
                group.addTask {
                    let started = Log<String>()
                    let events = try await collect(c.ask("q\(i)", sessionId: "s", started: { started.add($0) }))
                    return (i, started.all[0], events)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(runs.count == 8)
        for (i, id, events) in runs {
            #expect(id == "r-q\(i)")
            #expect(events == [.feeling("happy"), .delta(id), .runEnded(status: "completed", output: id)])
        }
    }

    @Test func askThatCannotStartThrowsAndEmitsNothing() async {
        let c = client { _ in .json(500, ["error": ["message": "down"]]) }
        var seen: [Event] = []
        do {
            for try await e in c.ask("hi", sessionId: "s1") { seen.append(e) }
            Issue.record("expected a BrainError")
        } catch let e as BrainError {
            #expect(e.message == "Hermes error 500: down")
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(seen.isEmpty)
    }

    @Test func approvalShowsTheCommandNotJustTheCategory() {
        #expect(HermesClient.parse(["event": "approval.request", "description": "recursive delete",
                                    "command": "rm -rf ~/Documents"]) == .approvalNeeded("recursive delete: rm -rf ~/Documents"))
        #expect(HermesClient.parse(["event": "approval.request", "description": "Robo wants to open x.", "command": ""])
            == .approvalNeeded("Robo wants to open x."))
    }

    @Test func guardApprovalsShowOnlyTheGuardsOwnSentence() {
        #expect(HermesClient.parse(["event": "approval.request", "description": "Robo wants to open https://x.example/.",
                                    "command": "<browser_navigate> (plugin approval rule)"])
            == .approvalNeeded("Robo wants to open https://x.example/."))
    }

    @Test func desktopControlApprovalsAreMarked() {
        let ev = HermesClient.parse(["event": "approval.request", "description": "Allow computer_use to perform `click`?",
                                     "command": "computer_use: click (412, 300)"])
        guard case .approvalNeeded(let description, let desktop, _)? = ev else { Issue.record("not an approval"); return }
        #expect(desktop && description.contains("click"))
        #expect(HermesClient.parse(["event": "approval.request", "description": "recursive delete", "command": "rm -rf x"])
            == .approvalNeeded("recursive delete: rm -rf x"))
    }

    @Test func approvalsCarryTheirRequestId() {
        #expect(HermesClient.parse(["event": "approval.request", "description": "Robo wants to open https://x.example/.",
                                    "command": "<browser_navigate> (plugin approval rule)", "request_id": "9f2c"])
            == .approvalNeeded("Robo wants to open https://x.example/.", id: "9f2c"))
        #expect(HermesClient.parse(["event": "approval.request", "description": "recursive delete", "command": "rm -rf x"])
            == .approvalNeeded("recursive delete: rm -rf x", id: ""))  // none sent: the answer is the oldest one's
    }

    /// robo-guard's ask for a computer_use step in Outlook or Teams ("Robo wants to ..."): never marked as Hermes' own desktop
    /// approval, so the app shows it. Hermes' own approval of the same step (which here names Outlook too) stays marked: the user
    /// already answered the guard's ask for it and must not be asked twice.
    @Test func guardAsksForOutlookAndTeamsAreNeverDesktopApprovals() {
        for app in ["Microsoft Outlook", "Microsoft Teams", "com.microsoft.teams2"] {
            #expect(HermesClient.parse(["event": "approval.request", "description": "Robo wants to click in \(app) (computer_use).",
                                        "command": "<computer_use> (plugin approval rule)", "request_id": "g1"])
                == .approvalNeeded("Robo wants to click in \(app) (computer_use).", desktop: false, id: "g1"))
        }
        #expect(HermesClient.parse(["event": "approval.request", "description": "Allow computer_use to perform `focus_app`?",
                                    "command": "computer_use: focus 'Microsoft Outlook'", "request_id": "h1"])
            == .approvalNeeded("Allow computer_use to perform `focus_app`?: computer_use: focus 'Microsoft Outlook'", desktop: true, id: "h1"))
    }

    // MARK: the default session and a real socket

    /// httpx `trust_env=False`: the key must never meet a proxy, a cookie jar or a redirect.
    @Test func theDefaultSessionHasNoProxyNoCookiesAndNoRedirects() async throws {
        let config = HermesClient.makeSession().configuration
        #expect(config.connectionProxyDictionary?.isEmpty == true)
        #expect(config.httpCookieStorage == nil)
        let server = LoopbackServer { _, conn in
            conn.send("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }
        defer { server.close() }
        let c = HermesClient(baseURL: "http://127.0.0.1:\(server.port)", key: KEY)
        _ = try? await c.stop("r1")  // a 302 is no error to httpx either; what matters is where it went
        #expect(server.requests.map(\.path) == ["/v1/runs/r1/stop"])
    }

    /// The first event reaches the caller while the connection is still open (not after the stream ends).
    @Test func realServerStreamsIncrementally() async throws {
        let gate = DispatchSemaphore(value: 0)
        let late = Log<Bool>()
        let server = LoopbackServer { _, conn in
            conn.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
            conn.send(": open\n\n" + String(decoding: frame(0, "message.delta", ["delta": "first"]), as: UTF8.self))
            if gate.wait(timeout: .now() + 5) == .timedOut { late.add(true) }  // only finish once the client has parsed "first"
            conn.send(String(decoding: frame(1, "run.completed", ["output": "first"]), as: UTF8.self) + ": stream closed\n\n")
        }
        defer { server.close() }
        let c = HermesClient(baseURL: "http://127.0.0.1:\(server.port)", key: KEY)
        var events = c.events("r1").makeAsyncIterator()
        #expect(try await events.next() == .delta("first"))
        gate.signal()
        #expect(try await events.next() == .runEnded(status: "completed", output: "first"))
        #expect(try await events.next() == nil)
        #expect(late.all.isEmpty, "the first event only arrived after the stream ended")
        #expect(server.requests.first?.headers["authorization"] == "Bearer \(KEY)")
        #expect(server.requests.first?.path == "/v1/runs/r1/events")
    }
}
