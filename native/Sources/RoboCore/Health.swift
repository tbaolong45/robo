// Is the Hermes gateway answering? One tiny GET now and then, reported as ok / warn / bad.
// Port of src/robo/health.py.
import Foundation

/// What the HERMES header light shows: answering, one miss (amber), two misses in a row (red).
public enum HealthState: String, Sendable { case ok, warn, bad }

/// Polls `<gateway>/health` on its own task and calls `onState` from there (the app must hop to
/// the main actor). The first failure is `.warn`, the second in a row `.bad`; failures re-poll
/// after `retry` seconds, a good poll waits `every`.
public final class HealthPoller: @unchecked Sendable {
    public typealias Fetch = @Sendable (String) async throws -> Int  // URL -> HTTP status

    let health: String
    private let onState: @Sendable (HealthState) -> Void
    private let every: Double, retry: Double
    private let fetch: Fetch
    private let sleep: @Sendable (Double) async throws -> Void
    private let lock = NSLock()
    private var napping: Task<Void, Never>?  // the wait in progress, so a poke can cut it short
    private var poked = false
    private var stopped = false  // like Python's _stop: nothing clears it, so stop() before start() sticks
    private(set) var task: Task<Void, Never>?

    /// `fetch` and `sleep` are injectable so tests need no network and no real time.
    public init(url: String, onState: @escaping @Sendable (HealthState) -> Void, every: Double = 20,
                retry: Double = 5, fetch: @escaping Fetch = HealthPoller.status,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        health = url.components(separatedBy: "/p/")[0] + "/health"  // as setup._wait_healthy; no key needed
        self.onState = onState
        self.every = every
        self.retry = retry
        self.fetch = fetch
        self.sleep = sleep
    }

    /// Begin polling. Only the first call does anything (Python raises on a second one), and none
    /// does after `stop()`.
    public func start() {
        lock.withLock {
            guard task == nil, !stopped else { return }
            task = Task { await run() }
        }
    }

    /// Poll right now (a run just failed: don't wait out the interval).
    public func poke() {
        lock.withLock { if let nap = napping { nap.cancel() } else { poked = true } }
    }

    /// End the polling for good; a poll in flight finishes quietly without reporting.
    public func stop() {
        lock.withLock {
            stopped = true
            task?.cancel()
        }
    }

    private func run() async {
        var fails = 0
        while !Task.isCancelled {
            // any failure to ask is "not up"; the poller must outlive it
            fails = (try? await fetch(health)) == 200 ? 0 : fails + 1
            if Task.isCancelled { return }  // the window closed during the GET
            onState(fails == 0 ? .ok : fails == 1 ? .warn : .bad)
            await wait(fails > 0 ? retry : every)
        }
    }

    private func wait(_ seconds: Double) async {
        let nap = Task<Void, Never> { try? await sleep(seconds) }
        lock.withLock {
            if poked { poked = false; nap.cancel() } else { napping = nap }
        }
        await withTaskCancellationHandler { await nap.value } onCancel: { nap.cancel() }
        lock.withLock { napping = nil }
    }

    // MARK: the default getter

    private static let session = HermesClient.makeSession()

    /// A GET with a short timeout and no credentials, so no key can leak to a health check.
    static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 1.5)
        r.httpShouldHandleCookies = false
        return r
    }

    /// The HTTP status of a GET to `url`; throws if it could not be asked.
    public static let status: Fetch = { url in
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        let (_, response) = try await session.data(for: request(u))
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
