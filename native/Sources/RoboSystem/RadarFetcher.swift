// The radar's downloads: the public feeds of papers, news, jobs and contests. Like the calendar fetcher (CalendarLinks.swift) it is
// https only, with a cap on time and size and no cookies, and it adds what a feed fetched every day needs:
//   - a HOST ALLOWLIST: only the sources robo knows (`RadarHosts.builtin`) and the hosts of the feeds the user wrote in their own
//     profile note; a redirect to any other host (or to plain http) is refused
//   - a cache on disk, `<sha256 of the URL>.body` and `.json` (0600, in a 0700 folder; the URL itself is never written): the last
//     good body with its ETag / Last-Modified, so the next request is conditional and a 304 gives the body again
//   - manners: at least `gaps[host]` seconds between two requests to one host (arXiv 3 s, the rest 1 s), a User-Agent that names
//     robo (CTFtime refuses the default one), and a back-off of about a day after a source answered with an error
// Errors are fixed words and never carry the URL (a feed link may hold a token). Nothing is signed in, no cookie is kept, no body is
// sent: the only thing a source learns is the Mac's address and which category or company is watched.
import CryptoKit
import Foundation

/// Why a download failed, in fixed words.
public enum RadarFetchError: Error, CustomStringConvertible, Equatable, Sendable {
    case notAllowed, backedOff, http(Int), tooBig, offline, timedOut, failed(Int)

    public var description: String {
        switch self {
        case .notAllowed: "not an allowed source"
        case .backedOff: "failed lately, not tried again yet"
        case .http(let code): "HTTP \(code)"
        case .tooBig: "over the size limit"
        case .offline: "no connection"
        case .timedOut: "timed out"
        case .failed(let code): "network error (\(code))"
        }
    }

    /// The network was not there (yet) or too slow, which says nothing about the source: no back-off, and a run in which nothing
    /// answered is tried again later.
    public var transient: Bool {
        switch self {
        case .offline, .timedOut, .failed: true
        case .notAllowed, .backedOff, .http, .tooBig: false
        }
    }
}

public protocol RadarFetching: AnyObject, Sendable {
    /// The body of `url`, or a `RadarFetchError`.
    func fetch(_ url: URL) async throws -> Data
}

public enum RadarHosts {
    /// The blogs of labs and companies in the user's field, read as announcements. Each answered 200 on its own host with a feed robo
    /// parses (checked 2026-10-23); a feed that moves to another host is refused by the fetcher until it is updated here. Not here:
    /// MBZUAI (its news feed answers bots with 403) and Anthropic (no feed).
    public static let announcements: [(name: String, link: String)] = [
        ("OpenAI", "https://openai.com/news/rss.xml"),
        ("Google DeepMind", "https://deepmind.google/blog/rss.xml"),
        ("Hugging Face blog", "https://huggingface.co/blog/feed.xml"),
        ("Google Research", "https://research.google/blog/rss/"),
        ("NVIDIA", "https://developer.nvidia.com/blog/feed/"),
        ("Berkeley AI Research", "https://bair.berkeley.edu/blog/feed.xml"),
        ("Microsoft Research", "https://www.microsoft.com/en-us/research/feed/"),
    ]

    public static let builtin = Set([
        "rss.arxiv.org", "huggingface.co", "hacker-news.firebaseio.com", "ctftime.org", "codeforces.com", "raw.githubusercontent.com",
        "boards-api.greenhouse.io", "api.lever.co", "api.ashbyhq.com", "api.github.com",
    ]).union(announcements.compactMap { URL(string: $0.link)?.host()?.lowercased() })

    /// The host of a feed the user wrote in their profile: https and a name, not an address on this network (an IP number,
    /// localhost, .local). ponytail: a LAN host name still passes; it is the user's own note.
    public static func userHost(_ link: String) -> String? {
        guard let url = URL(string: link), url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), host.contains("."),
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }), !host.hasSuffix(".local"), host != "localhost" else { return nil }
        return host
    }
}

public final class RadarFetcher: RadarFetching, @unchecked Sendable {
    public static let userAgent = "Robo/1.0 (personal study assistant)"
    public static let timeout: TimeInterval = 20
    /// A source that answered with an error is left alone this long. A bit under a day, so tomorrow's run (which may start a
    /// little before this hour) still tries it.
    public static let backoff: TimeInterval = 20 * 3600
    public static let keepCache: TimeInterval = 30 * 86_400
    public static let defaultMaxBytes = 4_000_000
    public static let caps = ["rss.arxiv.org": 8_000_000, "raw.githubusercontent.com": 24_000_000]  // arXiv's mailing; SimplifyJobs' listings
    /// Seconds between two requests to a host. Hacker News gets 0.25 s: its 30 story requests (6 at a time) must fit in 15 s.
    public static let gaps = ["rss.arxiv.org": 3.0, "hacker-news.firebaseio.com": 0.25]
    public static let defaultGap = 1.0

    private let dir: URL
    private let extraHosts: Set<String>
    private let caps: [String: Int]
    private let defaultMax: Int
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let session: URLSession
    private let lock = NSLock()
    private var last: [String: Double] = [:]  // host -> when (seconds) the last request to it starts

    /// `configuration` is the session's (a test hands in one with a stub protocol); the limits are set here either way. `now` and
    /// `sleep` are the clock and the wait between two requests to one host: a test hands in fakes.
    public init(cacheDir: URL, extraHosts: Set<String> = [], configuration: URLSessionConfiguration = .ephemeral,
                caps: [String: Int] = RadarFetcher.caps, defaultMaxBytes: Int = RadarFetcher.defaultMaxBytes,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        (dir, self.extraHosts, self.caps, defaultMax, self.now, self.sleep) = (cacheDir, extraHosts, caps, defaultMaxBytes, now, sleep)
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        session = URLSession(configuration: configuration)
        prune()
    }

    /// Whether robo may fetch `url`: https on the default port, no credentials, a host of the list (exact, no sub-domain match).
    static func allowed(_ url: URL, extra: Set<String>) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user() == nil, url.password() == nil, url.port == nil || url.port == 443,
              let host = url.host()?.lowercased() else { return false }
        return RadarHosts.builtin.contains(host) || extra.contains(host)
    }

    /// Refuses a redirect to another host, to plain http or to a host that is not on the list.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        let host: String, extra: Set<String>
        init(host: String, extra: Set<String>) { (self.host, self.extra) = (host, extra) }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let ok = request.url.map { RadarFetcher.allowed($0, extra: extra) && $0.host()?.lowercased() == host } ?? false
            completionHandler(ok ? request : nil)
        }
    }

    // MARK: the cache

    /// What is kept of a source besides its body: the validators for the next request, and until when it is left alone.
    private struct Meta: Codable {
        var etag: String?
        var lastModified: String?
        var failUntil: Date?
    }

    private func name(_ url: URL) -> String { SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func bodyFile(_ id: String) -> URL { dir.appendingPathComponent(id + ".body") }
    private func metaFile(_ id: String) -> URL { dir.appendingPathComponent(id + ".json") }

    private func readMeta(_ id: String) -> Meta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: metaFile(id))).flatMap { try? decoder.decode(Meta.self, from: $0) } ?? Meta()
    }

    /// The cache is a convenience: a write that fails costs a full download tomorrow, never an error.
    private func write(_ meta: Meta, _ id: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(meta) { try? NudgeFiles.atomicWrite(data, to: metaFile(id)) }
    }

    /// A source with no ETag and no Last-Modified cannot be asked conditionally: nothing is kept of it. The body goes first, so a
    /// crash in between leaves old validators with an old body, never new validators with an old body.
    private func store(_ body: Data, _ http: HTTPURLResponse, _ id: String) {
        let etag = http.value(forHTTPHeaderField: "ETag").flatMap { $0.isEmpty ? nil : $0 }
        let modified = http.value(forHTTPHeaderField: "Last-Modified").flatMap { $0.isEmpty ? nil : $0 }
        guard etag != nil || modified != nil else {
            try? FileManager.default.removeItem(at: bodyFile(id))
            try? FileManager.default.removeItem(at: metaFile(id))
            return
        }
        guard (try? NudgeFiles.atomicWrite(body, to: bodyFile(id))) != nil else { return }
        write(Meta(etag: etag, lastModified: modified), id)
    }

    /// Forgets what has not been asked for in `keepCache` (a feed the user dropped, a URL that changes every day).
    private func prune() {
        let fm = FileManager.default
        let cutoff = now().addingTimeInterval(-Self.keepCache)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.pathExtension == "json" {
            guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date < cutoff else { continue }
            try? fm.removeItem(at: file)
            try? fm.removeItem(at: file.deletingPathExtension().appendingPathExtension("body"))
        }
    }

    // MARK: the request

    /// Waits so that two requests to one host start `gap` seconds apart (several at once queue up one gap after the other).
    private func pace(_ host: String) async {
        let gap = Self.gaps[host] ?? Self.defaultGap
        let wait = lock.withLock { () -> Double in
            let t = now().timeIntervalSince1970
            let wait = min(max(0, (last[host] ?? -1e18) + gap - t), 60)  // a clock set back is not an hour of waiting
            last[host] = t + wait
            return wait
        }
        if wait > 0 { await sleep(wait) }
    }

    public func fetch(_ url: URL) async throws -> Data {
        guard Self.allowed(url, extra: extraHosts), let host = url.host()?.lowercased() else { throw RadarFetchError.notAllowed }
        let id = name(url)
        let before = readMeta(id)
        if let until = before.failUntil, until > now() { throw RadarFetchError.backedOff }
        var cached: Data?
        if before.etag != nil || before.lastModified != nil { cached = try? Data(contentsOf: bodyFile(id)) }
        await pace(host)
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if cached != nil {
            if let etag = before.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = before.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard(host: host, extra: extraHosts))
            guard let http = response as? HTTPURLResponse else { throw RadarFetchError.failed(0) }
            if http.statusCode == 304, let cached {
                write(Meta(etag: before.etag, lastModified: before.lastModified), id)  // asked again: kept, and no longer backed off
                return cached
            }
            guard http.statusCode == 200 else { throw RadarFetchError.http(http.statusCode) }
            let cap = caps[host] ?? defaultMax
            guard http.expectedContentLength <= cap else { throw RadarFetchError.tooBig }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > cap { throw RadarFetchError.tooBig }
            }
            store(body, http, id)
            return body
        } catch {
            let failure = Self.failure(error)
            if !failure.transient {
                var meta = before
                meta.failUntil = now().addingTimeInterval(Self.backoff)
                write(meta, id)
            }
            throw failure
        }
    }

    private static func failure(_ error: Error) -> RadarFetchError {
        if let e = error as? RadarFetchError { return e }
        guard let e = error as? URLError else { return .failed(0) }
        switch e.code {
        case .timedOut: return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            return .offline
        default: return .failed(e.code.rawValue)
        }
    }
}
