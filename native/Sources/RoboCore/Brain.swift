// Talk to Hermes Agent over its HTTP API server (`/v1/runs` + SSE events).
// Port of src/robo/brain.py.
import Foundation

/// A Hermes request failed; the message is safe to show the user.
public struct BrainError: Error, LocalizedError, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// How to answer a pending approval. There is no "always" on purpose.
public enum ApprovalChoice: String, Sendable {
    /// `session`: that kind of action for the rest of this run; robo uses it only for desktop control.
    case once, session, deny
}

private struct Malformed: Error {}

/// Declines every redirect (the 3xx comes back as the answer), as httpx does by default.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Splits SSE bytes into (id, data) events; comments and other fields are skipped.
struct SSEParser {
    private var line = [UInt8]()
    private var skipLF = false  // a "\r\n" ends one line, not two
    private var id: String?
    private var data = [String]()

    /// Feed one byte; an event comes back when a blank line completes it.
    mutating func feed(_ byte: UInt8) -> (id: String?, data: String)? {
        if byte == 10 && skipLF { skipLF = false; return nil }
        skipLF = byte == 13
        guard byte == 10 || byte == 13 else { line.append(byte); return nil }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            let event = data.isEmpty ? nil : (id: id, data: data.joined(separator: "\n"))
            id = nil
            data = []
            return event
        }
        if line.starts(with: "data:".utf8) {
            let value = line.dropFirst(5)
            data.append(String(decoding: value.first == 32 ? value.dropFirst() : value, as: UTF8.self))
        } else if line.starts(with: "id:".utf8) {
            id = String(decoding: line.dropFirst(3), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

/// Minimal client for one Hermes API server. It keeps no per-run state (the caller tracks the run id
/// that `ask` reports), only immutable settings, so any number of runs may use one client at once.
public final class HermesClient: Sendable {
    private static let terminal = ["run.completed", "run.failed", "run.cancelled", "run.interrupted"]

    private let base: String
    private let auth: String
    private let session: URLSession

    public init(baseURL: String, key: String, session: URLSession = HermesClient.makeSession()) {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        self.base = base
        auth = "Bearer \(key)"
        self.session = session
    }

    /// A session no proxy, cookie jar or redirect can get between robo and Hermes (httpx `trust_env=False`:
    /// a proxy from the environment must never see the key). URLSession has no separate connect
    /// timeout; a refused loopback connect fails at once, and each request carries its own idle timeout.
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// POST /v1/runs; the new run's id.
    public func startRun(_ text: String, sessionId: String) async throws -> String {
        let data = try await send("POST", "/v1/runs", ["input": text, "session_id": sessionId])
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = object?["run_id"] as? String else { throw BrainError("Hermes sent malformed data") }
        return id
    }

    /// Ask Hermes to stop a run.
    public func stop(_ runId: String) async throws {
        _ = try await send("POST", "/v1/runs/\(runId)/stop")
    }

    /// Answer a pending approval. `requestId` (from the `approval.request` event) names the request; without it Hermes
    /// answers the oldest one it has pending, which is not always the one the user saw.
    public func approve(_ runId: String, _ choice: ApprovalChoice, requestId: String = "") async throws {
        var body = ["choice": choice.rawValue]
        if !requestId.isEmpty { body["request_id"] = requestId }
        _ = try await send("POST", "/v1/runs/\(runId)/approval", body)
    }

    /// The run's events; always ends with exactly one `.runEnded` and never throws.
    ///
    /// A dropped stream is resumed once from the last event id (Hermes replays the rest). If
    /// that fails too the run is stopped, so it never keeps going with nobody watching.
    public func events(_ runId: String) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { out in
            let task = Task {
                await self.pump(runId, out)
                out.finish()
            }
            out.onTermination = { _ in task.cancel() }
        }
    }

    /// Start a run and stream its events with feel tags split into `.feeling`s. Throws `BrainError`
    /// if the run cannot be started. `started(runId)` is called as soon as the run exists, before
    /// any event arrives.
    public func ask(_ text: String, sessionId: String,
                    started: (@Sendable (String) -> Void)? = nil) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { out in
            let task = Task {
                do {
                    let id = try await self.startRun(text, sessionId: sessionId)
                    started?(id)
                    var feel = FeelingFilter()
                    for try await event in self.events(id) {
                        switch event {
                        case .delta(let text):
                            feel.feed(text).forEach { out.yield($0) }
                        case .runEnded(let status, let output, let error):
                            feel.finish().forEach { out.yield($0) }
                            out.yield(.runEnded(status: status, output: stripTags(output), error: error))
                        default:
                            out.yield(event)
                        }
                    }
                    out.finish()
                } catch {
                    out.finish(throwing: error)
                }
            }
            out.onTermination = { _ in task.cancel() }
        }
    }

    private func pump(_ runId: String, _ out: AsyncThrowingStream<Event, Error>.Continuation) async {
        var last: String?
        var failure = ""
        for _ in 0..<2 {
            do {
                var request = try makeRequest("GET", "/v1/runs/\(runId)/events", timeout: 120)
                if let last { request.setValue(last, forHTTPHeaderField: "Last-Event-ID") }
                let (bytes, response) = try await session.bytes(for: request)
                try await Self.check(response) {
                    var body = Data()
                    do { for try await byte in bytes { body.append(byte) } } catch {}
                    return body
                }
                var sse = SSEParser()
                for try await byte in bytes {
                    guard let frame = sse.feed(byte) else { continue }
                    let events = try Self.parse(frame.data)
                    if let id = frame.id, !id.isEmpty { last = id }
                    events.forEach { out.yield($0) }
                    if case .runEnded? = events.last { return }
                }
                failure = "Hermes stream ended without a result"
            } catch let e as BrainError {  // an error response: retrying would get the same
                out.yield(.runEnded(status: "failed", error: e.message))
                return
            } catch {
                if Task.isCancelled { return }  // the consumer left
                failure = Self.describe(error)
            }
        }
        try? await stop(runId)
        if !Task.isCancelled { out.yield(.runEnded(status: "failed", error: failure)) }
    }

    private func makeRequest(_ method: String, _ path: String, timeout: Double) throws -> URLRequest {
        guard let url = URL(string: base + path) else { throw BrainError("Hermes address looks wrong: \(base)") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ method: String, _ path: String, _ body: [String: String]? = nil) async throws -> Data {
        var request = try makeRequest(method, path, timeout: 15)
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw BrainError(Self.describe(error)) }
        try await Self.check(response) { data }
        return data
    }

    private static func describe(_ e: Error) -> String {
        if e is Malformed { return "Hermes sent malformed data" }
        guard let e = e as? URLError else { return "Hermes connection failed (\(type(of: e)))" }
        switch e.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return "Hermes is not running (connection refused); start it with `hermes gateway start`."
        case .timedOut:
            return "Hermes timed out"
        default:
            return "Hermes connection failed (URLError \(e.code.rawValue))"
        }
    }

    /// Throw `BrainError` for an error response.
    private static func check(_ response: URLResponse, body: () async -> Data) async throws {
        guard let r = response as? HTTPURLResponse, r.statusCode >= 400 else { return }
        if r.statusCode == 401 { throw BrainError("Hermes rejected the API key (401); run `robo setup` again.") }
        let object = try? JSONSerialization.jsonObject(with: await body()) as? [String: Any]
        let detail = ((object?["error"] as? [String: Any])?["message"] as? String)
            ?? HTTPURLResponse.localizedString(forStatusCode: r.statusCode).capitalized
        throw BrainError("Hermes error \(r.statusCode): \(detail)")
    }

    /// The events of one frame: a `run.completed` that reports its usage gives `.usage` first, then `.runEnded`.
    static func parse(_ json: String) throws -> [Event] {
        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw Malformed() }
        return [usage(d).map { .usage($0) }, parse(d)].compactMap { $0 }
    }

    /// The tokens and the model of a `run.completed` frame (`usage`: input_tokens, output_tokens, total_tokens, cache_read_tokens,
    /// cache_write_tokens; `runtime`: provider, model); nil for any other frame, or one without a `usage` object.
    static func usage(_ d: [String: Any]) -> UsageRecord? {
        guard d["event"] as? String == "run.completed", let u = d["usage"] as? [String: Any], !u.isEmpty else { return nil }
        let (input, output) = (u["input_tokens"] as? Int ?? 0, u["output_tokens"] as? Int ?? 0)
        return UsageRecord(model: (d["runtime"] as? [String: Any])?["model"] as? String ?? "", input: input, output: output,
                           total: u["total_tokens"] as? Int ?? input + output, cacheRead: u["cache_read_tokens"] as? Int ?? 0,
                           cacheWrite: u["cache_write_tokens"] as? Int ?? 0)
    }

    /// Map one Hermes run event to a robo event (nil for ones robo ignores).
    static func parse(_ d: [String: Any]) -> Event? {
        guard let name = d["event"] as? String else { return nil }
        switch name {
        case "message.delta":
            return .delta(d["delta"] as? String ?? "")
        case "tool.started":
            return .toolStarted(d["tool"] as? String ?? "")
        case "tool.completed":
            return .toolCompleted(tool: d["tool"] as? String ?? "", error: d["error"] as? Bool ?? false)
        case "approval.request":
            let what = d["description"] as? String ?? ""
            var command = d["command"] as? String ?? ""
            if command.hasSuffix("(plugin approval rule)") { command = "" }  // robo-guard's sentence says it all
            // desktop = the DESCRIPTION is Hermes' own fixed sentence (tools/computer_use `Allow computer_use to perform ...`).
            // robo-guard's asks (also computer_use steps in Outlook or Teams) all begin "Robo wants to", so they never match.
            return .approvalNeeded(!what.isEmpty && !command.isEmpty ? "\(what): \(command)" : what.isEmpty ? command : what,
                                   desktop: what.hasPrefix("Allow computer_use"), id: d["request_id"] as? String ?? "")
        case _ where terminal.contains(name):
            return .runEnded(status: String(name.dropFirst("run.".count)), output: d["output"] as? String ?? "",
                             error: d["error"] as? String ?? "")
        default:
            return nil
        }
    }
}
