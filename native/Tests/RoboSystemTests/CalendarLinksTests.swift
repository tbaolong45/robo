// The calendar links (an Outlook or Moodle calendar link is a secret URL): the store, the https-only fetcher, `robo calendar`,
// the link file and the three nudge files. No test touches the real data folder (an in-memory store or a temp folder stands in) or
// the network (a stub URLProtocol answers). The thing under test above all: the secret never shows in an output, an error or a log.
import Foundation
import RoboCore
import Testing
@testable import RoboSystem

private let secret = "SECRETTOKEN0123456789"
private let outlook = "https://outlook.example.com/owa/calendar/\(secret)/reachcalendar.ics?x=\(secret)"

/// The link file's role, in a dictionary; `failing` makes every call fail the way a file that cannot be written does.
private final class MemoryStore: SecretStore {
    var items: [String: String] = [:]
    var failing = false
    func accounts() throws -> [String] {
        if failing { throw SecretError("the store refused") }
        return items.keys.sorted()
    }
    func secret(for account: String) throws -> String? { items[account] }
    func set(_ secret: String, for account: String) throws { items[account] = secret }
    func remove(account: String) throws -> Bool {
        if failing { throw SecretError("the store refused") }
        return items.removeValue(forKey: account) != nil
    }
}

/// A fetcher with a script: the body for a label's URL, or an error.
private final class FakeFetcher: CalendarFetching, @unchecked Sendable {
    var answers: [String: Result<Data, CalendarFetchError>] = [:]  // by URL string
    var asked: [URL] = []
    func fetch(_ url: URL) async throws -> Data {
        asked.append(url)
        return try (answers[url.absoluteString] ?? .failure(CalendarFetchError("HTTP 404"))).get()
    }
}

private let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!
private let utc = TimeZone(identifier: "UTC")!

private func ics(_ events: String..., crlf: Bool = true) -> Data {
    let lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//test//EN"] + events.flatMap { $0.split(separator: "\n").map(String.init) } + ["END:VCALENDAR"]
    return Data((lines.joined(separator: crlf ? "\r\n" : "\n") + "\r\n").utf8)
}

private func event(_ uid: String, _ summary: String, _ start: String, _ extra: String = "") -> String {
    "BEGIN:VEVENT\nUID:\(uid)\nSUMMARY:\(summary)\nDTSTART:\(start)\n\(extra)END:VEVENT"
}

private func withTemp<T>(_ body: (URL) throws -> T) rethrows -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("robo-test-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

private func mode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)!.intValue & 0o7777
}

// MARK: - links

@Suite struct CalendarURLTests {
    @Test func httpsAndWebcalAreFetchedAsHttps() {
        #expect(CalendarURL.normalize("https://a.example.com/x.ics?k=1")?.absoluteString == "https://a.example.com/x.ics?k=1")
        #expect(CalendarURL.normalize("  webcal://a.example.com/x.ics \n")?.absoluteString == "https://a.example.com/x.ics")
        #expect(CalendarURL.normalize("WEBCAL://a.example.com/x.ics")?.absoluteString == "https://a.example.com/x.ics")
        #expect(CalendarURL.normalize("webcals://a.example.com/x.ics")?.absoluteString == "https://a.example.com/x.ics")
    }

    @Test func nothingElseIsAccepted() {
        for bad in ["http://a.example.com/x.ics", "ftp://a.example.com/x.ics", "file:///etc/passwd", "javascript:alert(1)",
                    "a.example.com/x.ics", "https://", "https:///x", "", "   ", "not a url", "https://" + String(repeating: "a", count: 3000)] {
            #expect(CalendarURL.normalize(bad) == nil, "\(bad.prefix(40))")
        }
    }

    @Test func plainHttpIsOnlyForTheMacItself() {
        for ok in ["http://localhost:8099/c.ics", "http://127.0.0.1:8099/c.ics", "http://[::1]:8099/c.ics"] { #expect(CalendarURL.normalize(ok) != nil, "\(ok)") }
        #expect(CalendarURL.normalize("http://192.168.1.5/c.ics") == nil && CalendarURL.normalize("http://localhost.evil.example/c.ics") == nil)
    }

    @Test func aLinkIsShownAsSchemeAndHostOnly() {
        let url = CalendarURL.normalize(outlook)!
        #expect(CalendarURL.redacted(url) == "https://outlook.example.com")
        #expect(!CalendarURL.redacted(url).contains(secret))
    }
}

@Suite struct CalendarSourcesTests {
    @Test func addListRemoveKeepTheSecretInTheStoreAndShowOnlyTheHost() throws {
        let store = MemoryStore()
        let sources = CalendarSources(store: store)
        #expect(try sources.list().isEmpty)
        #expect(try sources.add(outlook) == false)  // new
        #expect(try sources.add("webcal://moodle.example.edu/export.ics?token=\(secret)", label: "moodle") == false)
        #expect(try sources.add("https://other.example.com/new.ics", label: "calendar") == true)  // the label is taken: replaced
        #expect(store.items["moodle"] == "https://moodle.example.edu/export.ics?token=\(secret)")
        let listed = try sources.list()
        #expect(listed.map(\.label) == ["calendar", "moodle"] && listed.map(\.link) == ["https://other.example.com", "https://moodle.example.edu"])
        #expect(!listed.map(\.link).joined().contains(secret))
        #expect(try sources.urls().map(\.url.absoluteString) == ["https://other.example.com/new.ics", "https://moodle.example.edu/export.ics?token=\(secret)"])
        #expect(try sources.remove("moodle") && !(try sources.remove("moodle")))
        #expect(store.items.keys.sorted() == ["calendar"])
    }

    @Test func aBadLinkOrLabelIsRefusedBeforeAnythingIsStored() {
        let store = MemoryStore()
        let sources = CalendarSources(store: store)
        #expect(throws: CalendarLinkError.badLink) { try sources.add("http://a.example.com/x.ics") }
        for label in ["", "has space", "semi;colon", "é", String(repeating: "a", count: 41), "../x"] {
            #expect(throws: CalendarLinkError.badLabel) { try sources.add(outlook, label: label) }
        }
        #expect(store.items.isEmpty)
        #expect(CalendarLinkError.badLink.description.contains(secret) == false)
    }

    @Test func fetchAllNamesAFailingLinkByLabelAndNeverByAddress() async throws {
        let store = MemoryStore()
        let sources = CalendarSources(store: store)
        try sources.add(outlook, label: "outlook")
        try sources.add("https://moodle.example.edu/export.ics?token=\(secret)", label: "moodle")
        let fetcher = FakeFetcher()
        fetcher.answers[outlook] = .success(Data("A".utf8))
        let got = await sources.fetchAll(using: fetcher)
        #expect(got.links == 2 && got.bodies == [Data("A".utf8)] && got.failures == ["moodle: HTTP 404"])
        #expect(!got.failures.joined().contains(secret) && !got.failures.joined().contains("moodle.example.edu"))
        #expect(await CalendarSources(store: MemoryStore()).fetchAll(using: fetcher).links == 0)  // no link: nothing to fetch, nothing failed
        store.failing = true
        let locked = await sources.fetchAll(using: fetcher)
        #expect(locked.bodies.isEmpty && locked.failures == ["the store refused"])
    }
}

// MARK: - the link file

@Suite struct FileSecretStoreTests {
    private func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("robo-test-" + UUID().uuidString) }

    @Test func linksRoundTripThroughAPrivateFileInAPrivateFolder() throws {
        let dir = tempDir().appendingPathComponent("a/robo")  // a folder that does not exist yet
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = FileSecretStore(dir: dir)
        #expect(try store.accounts().isEmpty && store.file.lastPathComponent == "calendars.json" && store.file.deletingLastPathComponent().path == dir.path)
        try store.set("https://a.example.com/x.ics?k=\(secret)", for: "outlook")
        try store.set("https://b.example.edu/y.ics", for: "moodle")
        #expect(try store.accounts() == ["moodle", "outlook"])
        #expect(try store.secret(for: "outlook") == "https://a.example.com/x.ics?k=\(secret)" && (try store.secret(for: "nope")) == nil)
        #expect(mode(dir) == 0o700 && mode(store.file) == 0o600)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: String]
        #expect(json == ["outlook": "https://a.example.com/x.ics?k=\(secret)", "moodle": "https://b.example.edu/y.ics"])  // plain JSON, label -> link
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["calendars.json"])  // no temp file left
        #expect(try FileSecretStore(dir: dir).accounts() == ["moodle", "outlook"])  // a second store (a restart) sees them
    }

    @Test func aLabelIsOverwrittenAndOtherLabelsStay() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSecretStore(dir: dir)
        try store.set("https://a.example.com/1", for: "x")
        try store.set("https://b.example.com/2", for: "y")
        try store.set("https://a.example.com/3", for: "x")
        #expect(try store.secret(for: "x") == "https://a.example.com/3" && store.secret(for: "y") == "https://b.example.com/2")
        #expect(try store.accounts() == ["x", "y"])
    }

    @Test func removeSaysWhetherItWasThereAndKeepsTheRest() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSecretStore(dir: dir)
        #expect(try store.remove(account: "x") == false && !FileManager.default.fileExists(atPath: store.file.path))  // nothing to write
        try store.set("https://a.example.com/1", for: "x")
        try store.set("https://b.example.com/2", for: "y")
        #expect(try store.remove(account: "x") && !(try store.remove(account: "x")))
        #expect(try store.accounts() == ["y"])
        #expect(try store.remove(account: "y") && (try store.accounts()).isEmpty)
        #expect(String(decoding: try Data(contentsOf: store.file), as: UTF8.self).contains("https") == false)  // the link is gone from the file
    }

    @Test func aMissingOrBrokenFileReadsAsEmptyAndNeverCrashes() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileSecretStore(dir: dir)
        #expect(try store.accounts().isEmpty && store.secret(for: "x") == nil)
        for junk in ["{ not json", "", "[\"a\", \"b\"]", "{\"a\": 1}", "{\"a\": {\"b\": \"c\"}}", "null", String(repeating: "\u{0}", count: 50)] {
            try Data(junk.utf8).write(to: store.file)
            #expect(try store.accounts().isEmpty && store.secret(for: "a") == nil, "\(junk.prefix(20))")
        }
        try store.set("https://a.example.com/1", for: "x")  // the next write makes a good file of it
        #expect(try store.accounts() == ["x"] && mode(store.file) == 0o600)
    }

    @Test func aLoosenedFileIsPrivateAgainAfterTheNextWrite() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSecretStore(dir: dir)
        try store.set("https://a.example.com/1", for: "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.file.path)
        try store.set("https://a.example.com/2", for: "x")
        #expect(mode(store.file) == 0o600)
    }

    @Test func aFolderThatCannotBeWrittenIsAnErrorInFixedWordsWithoutTheLink() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("file")
        try Data().write(to: blocker)
        let store = FileSecretStore(dir: blocker.appendingPathComponent("sub"))  // a folder under a plain file
        do {
            try store.set(outlook, for: "x")
            Issue.record("the write should have failed")
        } catch {
            #expect("\(error)" == "could not write calendars.json" && !"\(error)".contains(secret))
        }
        #expect(try store.accounts().isEmpty)
    }

    @Test func theCommandsWorkOnTheFileAndTheLinkIsOnlyEverInTheFile() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sources = CalendarSources(store: FileSecretStore(dir: dir))
        func run(_ args: [String]) async -> (status: Int32, stdout: String, stderr: String) {
            let r = await calendarReport(args, sources: sources, fetcher: FakeFetcher(), now: now, zone: utc)
            for word in [secret, "reachcalendar", outlook] { #expect(!(r.stdout + r.stderr).contains(word), "\(args.first ?? "") printed the link") }
            return r
        }
        let added = await run(["add", outlook, "--label", "outlook"])
        #expect(added.status == 0 && added.stdout.contains("(https://outlook.example.com)") && added.stdout.contains("private file"))
        let stored = try String(contentsOf: dir.appendingPathComponent("calendars.json"), encoding: .utf8)
        #expect(stored.contains(outlook) && mode(dir.appendingPathComponent("calendars.json")) == 0o600)  // here, and only here
        let listed = await run(["list"])
        #expect(listed.stdout == "outlook  https://outlook.example.com\n")
        let checked = await run(["check"])  // the fake fetcher answers 404 for it
        #expect(checked.status == 1 && checked.stderr == "robo: outlook: HTTP 404\n")
        let gone = await run(["remove", "outlook"])
        let after = await run(["list"])
        #expect(gone.status == 0 && after.stdout.contains("No calendar added"))
    }

    @Test func theRealCommandTakesItsFolderFromTheCallerSoATestNeverTouchesTheRealOne() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let status = await runCalendar(["list"], dir: dir)  // prints "No calendar added" to this test's stdout
        #expect(status == 0 && !FileManager.default.fileExists(atPath: dir.path))  // listing writes nothing, not even the folder
    }
}

// MARK: - the fetcher

/// Answers every request of a session built with it, from `handler`; records what was asked.
private final class StubProtocol: URLProtocol {
    enum Reply {
        case body(Data, status: Int = 200, headers: [String: String] = [:])
        case redirect(String)
        case fail(URLError.Code)
    }
    nonisolated(unsafe) static var handler: (URLRequest) -> Reply = { _ in .fail(.badServerResponse) }
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request)
        let url = request.url!
        switch Self.handler(request) {
        case .body(let data, let status, let headers):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let to):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": to])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: to)!), redirectResponse: response)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code, userInfo: [NSURLErrorFailingURLStringErrorKey: url.absoluteString]))
        }
    }

    static func fetcher() -> CalendarFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return CalendarFetcher(configuration: config)
    }
}

@Suite(.serialized) struct CalendarFetcherTests {
    private let url = CalendarURL.normalize(outlook)!

    private func fetching(_ reply: @escaping (URLRequest) -> StubProtocol.Reply) -> CalendarFetcher {
        StubProtocol.requests = []
        StubProtocol.handler = reply
        return StubProtocol.fetcher()
    }

    /// The error a fetch ends in, as the words it says.
    private func failure(_ fetcher: CalendarFetcher, _ url: URL) async -> String? {
        do { _ = try await fetcher.fetch(url) } catch { return (error as? CalendarFetchError)?.description ?? "other: \(error)" }
        return nil
    }

    @Test func itAsksPoliteAndPlainlyAndGetsTheBody() async throws {
        let fetcher = fetching { _ in .body(Data("BODY".utf8)) }
        #expect(try await fetcher.fetch(url) == Data("BODY".utf8))
        let sent = StubProtocol.requests[0]
        #expect(sent.value(forHTTPHeaderField: "User-Agent") == "Robo/1.0" && sent.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(sent.value(forHTTPHeaderField: "If-None-Match") == nil && sent.url == url && sent.httpMethod == "GET")
    }

    @Test func anEtagComesBackAsIfNoneMatchAndA304GivesTheLastBodyAgain() async throws {
        let fetcher = fetching { r in
            r.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" ? .body(Data(), status: 304) : .body(Data("V1".utf8), headers: ["ETag": "\"v1\""])
        }
        #expect(try await fetcher.fetch(url) == Data("V1".utf8))
        #expect(try await fetcher.fetch(url) == Data("V1".utf8))  // 304: the remembered body
        #expect(StubProtocol.requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } == [nil, "\"v1\""])
        // An answer with no ETag forgets the old one: the next ask is plain again.
        StubProtocol.handler = { _ in .body(Data("V2".utf8)) }
        #expect(try await fetcher.fetch(url) == Data("V2".utf8))  // still conditional (the ETag was kept), answered in full
        #expect(try await fetcher.fetch(url) == Data("V2".utf8))
        #expect(StubProtocol.requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } == [nil, "\"v1\"", "\"v1\"", nil])
    }

    @Test func aFailureSaysWhatWentWrongInFixedWordsAndNeverTheAddress() async {
        let cases: [(StubProtocol.Reply, String)] = [
            (.body(Data(), status: 403), "HTTP 403"), (.body(Data(), status: 500), "HTTP 500"), (.fail(.timedOut), "timed out"),
            (.fail(.notConnectedToInternet), "no connection"), (.fail(.cannotFindHost), "no connection"),
            (.fail(.serverCertificateUntrusted), "the secure connection failed"), (.fail(.badServerResponse), "network error (-1011)"),
        ]
        for (reply, words) in cases {
            let said = await failure(fetching { _ in reply }, url)
            #expect(said == words, "\(words)")
            #expect(said?.contains(secret) == false && said?.contains("outlook.example.com") == false)
        }
    }

    @Test func itOnlyFetchesHttps() async {
        let fetcher = fetching { _ in .body(Data("x".utf8)) }
        #expect(await failure(fetcher, URL(string: "http://outlook.example.com/x.ics?k=\(secret)")!) == "not an https link")
        #expect(await failure(fetcher, URL(string: "file:///etc/passwd")!) == "not an https link")
        #expect(StubProtocol.requests.isEmpty)  // nothing went out
        #expect(await failure(fetcher, URL(string: "http://127.0.0.1:9/c.ics")!) == nil)  // the Mac itself may be plain http
    }

    @Test func aRedirectToAnythingButHttpsIsNotFollowed() {
        func follows(_ to: String) -> Bool {
            var followed = false
            let task = URLSession.shared.dataTask(with: url)
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": to])!
            CalendarFetcher.RedirectGuard().urlSession(.shared, task: task, willPerformHTTPRedirection: response,
                                                       newRequest: URLRequest(url: URL(string: to)!)) { followed = $0 != nil }
            return followed
        }
        #expect(follows("https://cdn.example.net/c.ics"))
        #expect(!follows("http://evil.example.net/steal?k=\(secret)") && !follows("http://192.168.1.5/c.ics") && !follows("file:///etc/passwd"))
    }

    @Test func anHttpsRedirectIsFollowed() async {
        let ok = fetching { r in r.url?.host == "outlook.example.com" ? .redirect("https://cdn.example.net/c.ics") : .body(Data("moved".utf8)) }
        #expect((try? await ok.fetch(url)) == Data("moved".utf8))
        #expect(StubProtocol.requests.map { $0.url?.host } == ["outlook.example.com", "cdn.example.net"])
    }

    @Test func aCalendarOverTheCapIsRefusedAndTheCapIsFourMegabytes() async throws {
        #expect(CalendarFetcher.defaultMaxBytes == 4_000_000 && StubProtocol.fetcher().maxBytes == 4_000_000 && CalendarFetcher.timeout == 20)
        func small() -> CalendarFetcher {  // a small cap, so the test does not push four million bytes through the loop
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubProtocol.self]
            return CalendarFetcher(configuration: config, maxBytes: 1000)
        }
        StubProtocol.requests = []
        StubProtocol.handler = { _ in .body(Data(repeating: 65, count: 1001)) }
        #expect(await failure(small(), url) == "the calendar is over 4 MB")  // no length announced: counted as it comes
        StubProtocol.handler = { _ in .body(Data("x".utf8), headers: ["Content-Length": "1001"]) }
        #expect(await failure(small(), url) == "the calendar is over 4 MB")  // announced: refused before reading
        StubProtocol.handler = { _ in .body(Data(repeating: 65, count: 1000)) }
        #expect(try await small().fetch(url).count == 1000)  // exactly the cap is fine
    }
}

// MARK: - `robo calendar`

@Suite struct CalendarCommandTests {
    private let hidden = [secret, "reachcalendar", "token="]  // nothing of the path or the query may ever be printed

    private func run(_ args: [String], store: MemoryStore, fetcher: FakeFetcher = FakeFetcher()) async -> (status: Int32, stdout: String, stderr: String) {
        let r = await calendarReport(args, sources: CalendarSources(store: store), fetcher: fetcher, now: now, zone: utc)
        for word in hidden + [outlook] { #expect(!(r.stdout + r.stderr).contains(word), "\(args.first ?? "") printed the link") }
        return r
    }

    @Test func addListRemoveRoundTripAndNeverPrintTheLink() async {
        let store = MemoryStore()
        let added = await run(["add", outlook], store: store)
        #expect(added.status == 0 && added.stdout.contains("Added calendar \"calendar\" (https://outlook.example.com)") && added.stderr.isEmpty)
        let more = await run(["add", "webcal://moodle.example.edu/export.ics?token=\(secret)", "--label", "moodle"], store: store)
        #expect(more.status == 0 && more.stdout.contains("\"moodle\" (https://moodle.example.edu)"))
        let inline = await run(["add", "--label=work", outlook], store: store)
        #expect(inline.status == 0 && inline.stdout.contains("\"work\""))
        let replaced = await run(["add", outlook], store: store)
        #expect(replaced.stdout.hasPrefix("Replaced calendar \"calendar\""))
        let listed = await run(["list"], store: store)
        #expect(listed.status == 0 && listed.stdout == "calendar  https://outlook.example.com\nmoodle  https://moodle.example.edu\nwork  https://outlook.example.com\n")
        let gone = await run(["remove", "work"], store: store)
        #expect(gone.status == 0 && gone.stdout == "Removed calendar \"work\".\n" && store.items.keys.sorted() == ["calendar", "moodle"])
        let missing = await run(["remove", "work"], store: store)
        #expect(missing.status == 1 && missing.stderr == "robo: no calendar labelled \"work\".\n")
    }

    @Test func anEmptyListSaysHowToAdd() async {
        let r = await run(["list"], store: MemoryStore())
        #expect(r.status == 0 && r.stdout.contains("No calendar added") && r.stderr.isEmpty)
        let c = await run(["check"], store: MemoryStore())
        #expect(c.status == 1 && c.stderr.contains("no calendar added"))
    }

    @Test func aBadCommandOrLinkIsAUsageErrorThatDoesNotEchoTheLink() async {
        let store = MemoryStore()
        for args in [[], ["bogus"], ["add"], ["add", outlook, "extra"], ["add", outlook, "--label"], ["add", "--bogus"], ["remove"], ["remove", "a", "b"],
                     ["list", "x"], ["check", "x"]] {
            let r = await run(args, store: store)
            #expect(r.status == 2 && r.stdout.isEmpty && r.stderr.hasPrefix("usage: robo calendar add URL"), "\(args)")
        }
        let http = await run(["add", "http://outlook.example.com/c.ics?token=\(secret)"], store: store)
        #expect(http.status == 2 && http.stderr == "robo: error: \(CalendarLinkError.badLink)\n")
        let label = await run(["add", outlook, "--label", "a b"], store: store)
        #expect(label.status == 2 && label.stderr == "robo: error: \(CalendarLinkError.badLabel)\n")
        #expect(store.items.isEmpty)
    }

    @Test func aStoreFailureIsExitOneWithItsFixedWords() async {
        let store = MemoryStore()
        store.failing = true
        for args in [["add", outlook], ["list"], ["remove", "x"], ["check"]] {
            let r = await run(args, store: store)
            #expect(r.status == 1 && r.stderr == "robo: the store refused\n", "\(args)")
        }
    }

    @Test func checkCountsWhatItParsedAndListsTheNextFiveThatCanBeReminded() async throws {
        let store = MemoryStore()
        _ = try CalendarSources(store: store).add(outlook, label: "outlook")
        let fetcher = FakeFetcher()
        fetcher.answers[outlook] = .success(ics(
            event("due-1", "Assignment 2 is due", "20261021T090000Z"),
            event("exam-1", "MATH201 midterm exam", "20261023T100000Z"),
            event("evil", "Lab \u{1B}[31mred\u{07} report is due", "20261022T100000Z"),
            event("lecture", "Lecture", "20261021T080000Z", "RRULE:FREQ=WEEKLY;COUNT=3\n"),
            event("past", "Old meeting", "20260101T080000Z"),
            "BEGIN:VEVENT\nUID:broken\nSUMMARY:No start\nEND:VEVENT"))
        let r = await run(["check"], store: store, fetcher: fetcher)
        #expect(r.status == 0 && r.stderr.isEmpty)
        let lines = r.stdout.split(separator: "\n").map(String.init)
        #expect(lines[0] == "outlook (https://outlook.example.com): 6 events parsed, 1 skipped, 3 of a series (never reminded)")
        #expect(Array(lines.dropFirst()) == ["  2026-10-21 09:00  deadline  Assignment 2 is due",
                                             "  2026-10-22 10:00  deadline  Lab  [31mred  report is due",
                                             "  2026-10-23 10:00  exam  MATH201 midterm exam"])
        #expect(!r.stdout.contains("\u{1B}") && !r.stdout.contains("\u{07}"))  // a feed cannot drive the terminal
    }

    @Test func checkReportsAFailingLinkAndGoesOnWithTheOthers() async throws {
        let store = MemoryStore()
        let sources = CalendarSources(store: store)
        try sources.add(outlook, label: "a")
        try sources.add("https://moodle.example.edu/export.ics?token=\(secret)", label: "b")
        let fetcher = FakeFetcher()
        fetcher.answers["https://moodle.example.edu/export.ics?token=\(secret)"] = .success(ics(event("d", "Quiz 1 deadline", "20261021T090000Z")))
        let r = await run(["check"], store: store, fetcher: fetcher)  // a: 404 from the fake; b: fine
        #expect(r.status == 1 && r.stderr == "robo: a: HTTP 404\n")
        #expect(r.stdout.contains("b (https://moodle.example.edu): 1 events parsed, 0 skipped") && r.stdout.contains("Quiz 1 deadline"))
        let empty = FakeFetcher()
        empty.answers[outlook] = .success(ics())
        _ = try sources.remove("b")
        let nothing = await run(["check"], store: store, fetcher: empty)
        #expect(nothing.status == 0 && nothing.stdout.contains("nothing coming up that robo would remind you of"))
    }
}

// MARK: - the three files

@Suite struct NudgeFilesTests {
    private func item(_ id: String, at when: Double = 1_792_000_000) -> AgendaItem {
        AgendaItem(id: id, title: "T \(id)", kind: .deadline, when: Date(timeIntervalSince1970: when), source: .ics, url: "https://a.example/x",
                   firstSeen: Date(timeIntervalSince1970: 1_791_000_000))
    }

    @Test func eachFileRoundTripsAndIsPrivate() throws {
        try withTemp { tmp in
            let dir = tmp.appendingPathComponent("a/robo")  // a folder that does not exist yet
            let files = NudgeFiles(dir: dir)
            #expect(files.loadAgenda().isEmpty && files.loadNudges() == NudgeState() && files.loadFired(now: now) == NudgeFiles.Fired())  // nothing yet
            var state = NudgeState()
            state.enabled = false
            state.sentToday = 2
            state.day = "2026-10-20"
            var fired = NudgeFiles.Fired()
            fired.keys["a|day|1"] = now
            fired.imported = true
            #expect(files.save([item("a"), item("b")]) && files.save(state) && files.save(fired))
            #expect(files.loadAgenda().map(\.id) == ["a", "b"] && files.loadNudges() == state && files.loadFired(now: now) == fired)
            #expect(mode(dir) == 0o700)  // the folder is made like the activity database's
            for file in [files.agendaFile, files.nudgesFile, files.remindersFile] { #expect(mode(file) == 0o600, "\(file.lastPathComponent)") }
            #expect(files.agendaFile.lastPathComponent == "agenda.json" && files.nudgesFile.lastPathComponent == "nudges.json"
                    && files.remindersFile.lastPathComponent == "reminders.json")
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            #expect(left == ["agenda.json", "nudges.json", "reminders.json"])  // no temp file left
        }
    }

    @Test func aRewriteReplacesTheFileAtomicallyAndStaysPrivate() throws {
        try withTemp { dir in
            let files = NudgeFiles(dir: dir)
            files.save([item("a")])
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: files.agendaFile.path)  // somebody loosened it
            files.save([item("b")])
            #expect(files.loadAgenda().map(\.id) == ["b"] && mode(files.agendaFile) == 0o600)
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            #expect(left == ["agenda.json"])
        }
    }

    @Test func aMissingBrokenOrNewerFileReadsAsWhatItCan() throws {
        try withTemp { dir in
            let files = NudgeFiles(dir: dir)
            for f in [files.agendaFile, files.nudgesFile, files.remindersFile] { try Data("{ not json".utf8).write(to: f) }
            #expect(files.loadAgenda().isEmpty && files.loadNudges() == NudgeState() && files.loadFired(now: now) == NudgeFiles.Fired())
            try Data("{\"fired\": {\"k\": \"2026-10-19T00:00:00Z\"}}".utf8).write(to: files.remindersFile)  // no "imported": false
            #expect(files.loadFired(now: now).keys.count == 1 && files.loadFired(now: now).imported == false)
            try Data("{}".utf8).write(to: files.remindersFile)
            #expect(files.loadFired(now: now) == NudgeFiles.Fired())
        }
    }

    @Test func aFiredReminderIsForgottenAfterSixtyDays() {
        withTemp { dir in
            let files = NudgeFiles(dir: dir)
            var fired = NudgeFiles.Fired()
            fired.keys = ["old": now.addingTimeInterval(-61 * 86_400), "edge": now.addingTimeInterval(-59 * 86_400), "new": now]
            files.save(fired)
            #expect(files.loadFired(now: now).keys.keys.sorted() == ["edge", "new"])
        }
    }

    @Test func aFolderThatCannotBeWrittenIsANoOpNotACrash() throws {
        try withTemp { dir in
            let blocker = dir.appendingPathComponent("file")
            try Data().write(to: blocker)
            let files = NudgeFiles(dir: blocker.appendingPathComponent("sub"))  // a folder under a plain file
            #expect(files.save([item("a")]) == false && files.loadAgenda().isEmpty)
        }
    }
}
