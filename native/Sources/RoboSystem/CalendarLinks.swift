// The calendar links (an Outlook "publish calendar" link, a Moodle export): each is a SECRET URL (anyone who has it can read the
// calendar), so it is kept in a private file (`calendars.json`, 0600, in robo's data folder, like the Hermes key) and never in a
// log, an output or an error message. What may be shown of one is `scheme://host`. The fetcher is https only, with a cap on time
// and size. `robo calendar add|list|remove|check` is `runCalendar`; the app reads the same store through
// `CalendarSources.fetchAll`. (Not the Keychain: its partition list pins an item to the cdhash of the build that wrote it, so every
// rebuild asked for the login password, and a background fetch hangs on that dialog.)
import Foundation
import RoboCore

// MARK: - the store

/// Secrets by account name. The real one is a file; the tests use a dictionary.
public protocol SecretStore: AnyObject {
    func accounts() throws -> [String]
    func secret(for account: String) throws -> String?
    func set(_ secret: String, for account: String) throws
    /// True when the account existed.
    func remove(account: String) throws -> Bool
}

/// A store call that failed, in fixed words: never an account or a secret.
public struct SecretError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The label -> link map as `calendars.json` in `dir`: `{"outlook": "https://...", ...}`. The folder is made 0700 and every write is
/// atomic and 0600 (`NudgeFiles.atomicWrite`). A file that is missing or cannot be read reads as empty, and nothing of its content is
/// ever logged or put in an error.
public final class FileSecretStore: SecretStore {
    public static let fileName = "calendars.json"
    public let file: URL

    public init(dir: URL) { file = dir.appendingPathComponent(Self.fileName) }

    private func load() -> [String: String] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    private func save(_ map: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        do { try NudgeFiles.atomicWrite(try encoder.encode(map), to: file) } catch { throw SecretError("could not write \(Self.fileName)") }
    }

    public func accounts() throws -> [String] { load().keys.sorted() }

    public func secret(for account: String) throws -> String? { load()[account] }

    public func set(_ secret: String, for account: String) throws {
        var map = load()
        map[account] = secret
        try save(map)
    }

    public func remove(account: String) throws -> Bool {
        var map = load()
        guard map.removeValue(forKey: account) != nil else { return false }
        try save(map)
        return true
    }
}

// MARK: - the links

public enum CalendarLinkError: Error, CustomStringConvertible, Equatable {
    case badLink, badLabel
    public var description: String {
        switch self {
        case .badLink: "the link must start with https:// or webcal:// (http:// only for localhost)"
        case .badLabel: "a label is 1 to 40 letters, digits, dots, dashes or underscores"
        }
    }
}

public enum CalendarURL {
    /// The link as robo fetches it: `webcal://` (and `webcals://`) read as `https://`. Only https is accepted; plain http only for
    /// a loopback host, where nothing leaves the Mac (a demo against a local server). nil for anything else.
    public static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["webcals://", "webcal://"] where text.lowercased().hasPrefix(scheme) {
            text = "https://" + text.dropFirst(scheme.count)
            break
        }
        guard text.utf8.count <= 2048, let url = URL(string: text), allowed(url) else { return nil }
        return url
    }

    /// Whether robo may fetch `url` (also asked of every redirect).
    public static func allowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        return scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    }

    /// What may be shown or logged of a link: `https://host`, never the path or the query (the token).
    public static func redacted(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "?")://\(url.host() ?? "?")"
    }
}

/// What a round of fetching brought: the body of each link that answered, and why the others did not (no link in it).
public struct CalendarBodies: Sendable {
    public var bodies: [Data] = []
    public var failures: [String] = []
    /// How many links there are; 0 = none added.
    public var links = 0
    public init(bodies: [Data] = [], failures: [String] = [], links: Int = 0) { (self.bodies, self.failures, self.links) = (bodies, failures, links) }
}

public struct CalendarSources {
    public static let defaultLabel = "calendar"
    private let store: SecretStore

    public init(store: SecretStore) { self.store = store }

    static func validLabel(_ label: String) -> Bool {
        (1...40).contains(label.count) && label.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || ".-_".unicodeScalars.contains($0)) }
    }

    /// Stores the link under `label`; true when that label was already there (the link is replaced).
    @discardableResult
    public func add(_ link: String, label: String = defaultLabel) throws -> Bool {
        guard Self.validLabel(label) else { throw CalendarLinkError.badLabel }
        guard let url = CalendarURL.normalize(link) else { throw CalendarLinkError.badLink }
        let existed = try store.accounts().contains(label)
        try store.set(url.absoluteString, for: label)
        return existed
    }

    /// The links by label, redacted to `scheme://host`.
    public func list() throws -> [(label: String, link: String)] {
        try urls().map { ($0.label, CalendarURL.redacted($0.url)) }
    }

    /// True when the label existed.
    public func remove(_ label: String) throws -> Bool { try store.remove(account: label) }

    /// The links with their secret URLs, for fetching. Never print these.
    public func urls() throws -> [(label: String, url: URL)] {
        try store.accounts().compactMap { label in
            try store.secret(for: label).flatMap(CalendarURL.normalize).map { (label, $0) }
        }
    }

    /// Fetches every link, one after the other. A link that fails is named in `failures` with the fetcher's own words.
    public func fetchAll(using fetcher: CalendarFetching) async -> CalendarBodies {
        var out = CalendarBodies()
        let links: [(label: String, url: URL)]
        do { links = try urls() } catch {
            out.failures.append((error as? SecretError)?.description ?? "the calendar links could not be read")
            return out
        }
        out.links = links.count
        for (label, url) in links {
            do { out.bodies.append(try await fetcher.fetch(url)) } catch {
                out.failures.append("\(label): \((error as? CalendarFetchError)?.description ?? "failed")")
            }
        }
        return out
    }
}

// MARK: - the fetcher

/// Why a download failed, in fixed words: it never carries the URL (a URLError would).
public struct CalendarFetchError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

public protocol CalendarFetching: AnyObject, Sendable {
    /// The body of the calendar at `url`.
    func fetch(_ url: URL) async throws -> Data
}

/// An ephemeral session: no cookies, no cache, no credentials stored. 20 s, 4 MB, https (a redirect to anything else is refused),
/// `If-None-Match` with the ETag of the last answer (a 304 gives that answer again). The answers are kept in memory only.
public final class CalendarFetcher: CalendarFetching, @unchecked Sendable {
    public static let defaultMaxBytes = 4_000_000
    public static let timeout: TimeInterval = 20

    public let maxBytes: Int
    private let session: URLSession
    private let lock = NSLock()
    private var known: [String: (etag: String, body: Data)] = [:]  // by URL, in memory only

    /// `configuration` is the session's (a test hands in one with a stub protocol); the limits are set here either way.
    public init(configuration: URLSessionConfiguration = .ephemeral, maxBytes: Int = CalendarFetcher.defaultMaxBytes) {
        self.maxBytes = maxBytes
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.httpAdditionalHeaders = ["User-Agent": "Robo/1.0"]
        session = URLSession(configuration: configuration)
    }

    /// Refuses a redirect to a link robo would not have fetched itself.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(CalendarURL.allowed) == true ? request : nil)
        }
    }

    public func fetch(_ url: URL) async throws -> Data {
        guard CalendarURL.allowed(url) else { throw CalendarFetchError("not an https link") }
        let key = url.absoluteString
        var request = URLRequest(url: url)
        let before = lock.withLock { known[key] }
        if let before { request.setValue(before.etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard())
            guard let http = response as? HTTPURLResponse else { throw CalendarFetchError("not an HTTP answer") }
            if http.statusCode == 304, let before { return before.body }
            guard http.statusCode == 200 else { throw CalendarFetchError("HTTP \(http.statusCode)") }
            guard http.expectedContentLength <= maxBytes else { throw CalendarFetchError("the calendar is over 4 MB") }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > maxBytes { throw CalendarFetchError("the calendar is over 4 MB") }
            }
            lock.withLock {
                if let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty { known[key] = (etag, body) } else { known[key] = nil }
            }
            return body
        } catch let e as CalendarFetchError {
            throw e
        } catch let e as URLError {
            throw CalendarFetchError(Self.reason(e.code))
        } catch {
            throw CalendarFetchError("the download failed")
        }
    }

    private static func reason(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: "timed out"
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: "no connection"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected: "the secure connection failed"
        case .cancelled: "cancelled"
        default: "network error (\(code.rawValue))"
        }
    }
}

// MARK: - `robo calendar`

private let calendarUsage = """
    usage: robo calendar add URL [--label NAME]
           robo calendar list
           robo calendar remove LABEL
           robo calendar check

    """

/// `robo calendar add|list|remove|check` (`args` follow `calendar`); the exit code. The links are in `calendars.json` of `dir`
/// (robo's data folder; follows $HOME, so a throwaway HOME gives a throwaway store).
public func runCalendar(_ args: [String], dir: URL = ActivityLog.dataDir) async -> Int32 {
    let r = await calendarReport(args, sources: CalendarSources(store: FileSecretStore(dir: dir)), fetcher: CalendarFetcher(), now: Date(),
                                 zone: .autoupdatingCurrent)
    FileHandle.standardOutput.write(Data(r.stdout.utf8))
    FileHandle.standardError.write(Data(r.stderr.utf8))
    return r.status
}

/// What `runCalendar` writes and returns: 2 for a bad command or link, 1 when the link file or a download fails. Nothing here
/// ever prints a URL, only `scheme://host`.
func calendarReport(_ args: [String], sources: CalendarSources, fetcher: CalendarFetching, now: Date,
                    zone: TimeZone) async -> (status: Int32, stdout: String, stderr: String) {
    var rest = args[...]
    let bad = (Int32(2), "", calendarUsage)
    switch rest.popFirst() {
    case "add":
        var link: String?
        var label = CalendarSources.defaultLabel
        while let a = rest.popFirst() {
            if a == "--label", let v = rest.popFirst() {
                label = v
            } else if a.hasPrefix("--label=") {
                label = String(a.dropFirst("--label=".count))
            } else if link == nil, !a.hasPrefix("--") {
                link = a
            } else {
                return bad
            }
        }
        guard let link else { return bad }
        do {
            let replaced = try sources.add(link, label: label)
            let host = CalendarURL.normalize(link).map(CalendarURL.redacted) ?? ""
            return (0, "\(replaced ? "Replaced" : "Added") calendar \"\(label)\" (\(host)). The link is kept in a private file (0600) of robo's data folder and never printed. Try `robo calendar check`.\n", "")
        } catch let e as CalendarLinkError {
            return (2, "", "robo: error: \(e)\n")
        } catch {
            return (1, "", "robo: \(error)\n")
        }
    case "list" where rest.isEmpty:
        do {
            let all = try sources.list()
            return (0, all.isEmpty ? "No calendar added. Add one with `robo calendar add URL`.\n" : all.map { "\($0.label)  \($0.link)\n" }.joined(), "")
        } catch {
            return (1, "", "robo: \(error)\n")
        }
    case "remove":
        guard let label = rest.popFirst(), rest.isEmpty else { return bad }
        do {
            return try sources.remove(label) ? (0, "Removed calendar \"\(label)\".\n", "") : (1, "", "robo: no calendar labelled \"\(label)\".\n")
        } catch {
            return (1, "", "robo: \(error)\n")
        }
    case "check" where rest.isEmpty:
        return await check(sources, fetcher, now, zone)
    default:
        return bad
    }
}

/// Fetch and parse every link once: how many events, how many skipped, the next five things that can be reminded.
private func check(_ sources: CalendarSources, _ fetcher: CalendarFetching, _ now: Date, _ zone: TimeZone) async -> (status: Int32, stdout: String, stderr: String) {
    let links: [(label: String, url: URL)]
    do { links = try sources.urls() } catch { return (1, "", "robo: \(error)\n") }
    guard !links.isEmpty else { return (1, "", "robo: no calendar added. Add one with `robo calendar add URL`.\n") }
    let when = DateFormatter()
    when.locale = Locale(identifier: "en_US_POSIX")
    when.timeZone = zone
    when.dateFormat = "yyyy-MM-dd HH:mm"
    var out = "", err = ""
    var status: Int32 = 0
    for (label, url) in links {
        do {
            let parsed = ICS.parse(try await fetcher.fetch(url), now: now, zone: zone)
            let items = Agenda.fromICS(parsed.events, now: now)
            let next = items.filter { !$0.recurring && $0.when >= now }.prefix(5)
            out += "\(label) (\(CalendarURL.redacted(url))): \(parsed.events.count) events parsed, \(parsed.skipped) skipped, "
                + "\(items.filter(\.recurring).count) of a series (never reminded)\n"
            for item in next { out += "  \(when.string(from: item.when))  \(item.kind.rawValue)  \(printable(item.title))\n" }
            if next.isEmpty { out += "  nothing coming up that robo would remind you of\n" }
        } catch {
            err += "robo: \(label): \((error as? CalendarFetchError)?.description ?? "failed")\n"
            status = 1
        }
    }
    return (status, out, err)
}

/// A title from a feed, for a terminal: no control characters (an escape sequence would be run by it), at most 80 characters.
private func printable(_ text: String) -> String {
    let kept = text.unicodeScalars.map { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ? " " : Character($0) }
    return String(kept.prefix(80))
}
