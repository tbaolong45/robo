// The radar's downloader and its file: the host allowlist, redirects, size caps, the cache on disk (an ETag gives a 304 that serves the
// cached body, and no file names the URL), the back-off after a failure, the gap between two requests to one host, and `radar.json`.
// No test touches the network (a stub URLProtocol answers, the clock and the waiting are fakes) or the real data folder (temp folders).
import Foundation
import RoboCore
import Testing
@testable import RoboSystem

private let secret = "SECRETTOKEN0123456789"
private let arxiv = URL(string: "https://rss.arxiv.org/atom/cs.CV")!
private let github = URL(string: "https://raw.githubusercontent.com/SimplifyJobs/Summer2027-Internships/dev/.github/scripts/listings.json")!
private let start = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!

private func withTemp<T>(_ body: (URL) async throws -> T) async rethrows -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("robo-radar-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}

private func mode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)!.intValue & 0o7777
}

/// Answers every request of a session built with it, from `handler`; records what was asked.
private final class Stub: URLProtocol {
    enum Reply {
        case body(Data, status: Int = 200, headers: [String: String] = [:])
        case redirect(String)
        case fail(URLError.Code)
    }
    nonisolated(unsafe) static var handler: (URLRequest) -> Reply = { _ in .fail(.badServerResponse) }
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private let state = NSLock()
    private var stopped = false
    override func stopLoading() { state.withLock { stopped = true } }

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
            // A followed redirect stops this load. One that the delegate refuses leaves the 302 as the answer, as a real server's
            // would be: delivered here unless the load was stopped in the meantime.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
                guard !state.withLock({ stopped }) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code, userInfo: [NSURLErrorFailingURLStringErrorKey: url.absoluteString]))
        }
    }
}

/// A clock the test moves, and a wait that only writes down how long it was asked to wait.
private final class Time: @unchecked Sendable {
    private let lock = NSLock()
    private var t = start.timeIntervalSince1970
    private var _waits: [Double] = []
    var date: Date { lock.withLock { Date(timeIntervalSince1970: t) } }
    var waits: [Double] { lock.withLock { _waits.sorted() } }
    func move(_ seconds: Double) { lock.withLock { t += seconds } }
    func wait(_ seconds: Double) async { lock.withLock { _waits.append(seconds) } }
}

private func fetcher(_ dir: URL, hosts: Set<String> = [], caps: [String: Int] = RadarFetcher.caps, max: Int = RadarFetcher.defaultMaxBytes,
                     time: Time = Time(), reply: @escaping (URLRequest) -> Stub.Reply) -> RadarFetcher {
    Stub.requests = []
    Stub.handler = reply
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Stub.self]
    return RadarFetcher(cacheDir: dir.appendingPathComponent("radar-cache"), extraHosts: hosts, configuration: config, caps: caps,
                        defaultMaxBytes: max, now: { time.date }, sleep: { await time.wait($0) })
}

/// The error a fetch ends in.
private func failure(_ f: RadarFetcher, _ url: URL) async -> RadarFetchError? {
    do { _ = try await f.fetch(url) } catch { return error as? RadarFetchError }
    return nil
}

// The stub's answers are one static table, so the suites that use it run one after the other (a serialized parent serializes its children).
@Suite(.serialized) struct RadarFetcherTests {

// MARK: - who may be asked

@Suite(.serialized) struct RadarAllowlistTests {
    @Test func onlyTheListedHostsOverHttpsAreFetched() async {
        await withTemp { dir in
            let f = fetcher(dir) { _ in .body(Data("x".utf8)) }
            for host in RadarHosts.builtin { #expect((try? await f.fetch(URL(string: "https://\(host)/x")!)) == Data("x".utf8), "\(host)") }
            #expect(RadarHosts.builtin.count == 9 && Stub.requests.count == 9)
            Stub.requests = []
            for bad in ["http://rss.arxiv.org/atom/cs.CV",  // plain http, even for a listed host
                        "https://evil.example.com/atom/cs.CV", "https://rss.arxiv.org.evil.example.com/x", "https://evil.example.com/rss.arxiv.org",
                        "https://sub.rss.arxiv.org/x", "https://arxiv.org/x", "https://user:pw@rss.arxiv.org/x", "https://rss.arxiv.org:8443/x",
                        "http://localhost:8099/x", "http://127.0.0.1/x", "https://127.0.0.1/x", "file:///etc/passwd", "ftp://rss.arxiv.org/x"] {
                #expect(await failure(f, URL(string: bad)!) == .notAllowed, "\(bad)")
            }
            #expect(Stub.requests.isEmpty)  // nothing went out
        }
    }

    @Test func theHostsOfTheUsersOwnFeedsAreAllowedOverHttpsOnly() async {
        await withTemp { dir in
            let feed = URL(string: "https://news.example.org/feed.xml?k=\(secret)")!
            #expect(await failure(fetcher(dir) { _ in .body(Data()) }, feed) == .notAllowed)
            let f = fetcher(dir, hosts: ["news.example.org"]) { _ in .body(Data("rss".utf8)) }
            let got = await failure(f, feed)
            #expect(got == nil, "\(String(describing: got))")
            #expect(await failure(f, URL(string: "http://news.example.org/feed.xml")!) == .notAllowed)
            #expect(await failure(f, URL(string: "https://other.example.org/feed.xml")!) == .notAllowed)
        }
    }

    @Test func aFeedHostIsAHostNameNotAnAddressOnThisNetwork() {
        #expect(RadarHosts.userHost("https://News.Example.org/rss.xml?k=1") == "news.example.org")
        for bad in ["http://news.example.org/x", "https://192.168.1.5/x", "https://10.0.0.1:8443/x", "https://[::1]/x", "https://localhost/x",
                    "https://printer.local/x", "https://intranet/x", "not a url", "", "javascript:alert(1)", "file:///etc/passwd"] {
            #expect(RadarHosts.userHost(bad) == nil, "\(bad)")
        }
    }
}

// MARK: - the request and the answer

@Suite(.serialized) struct RadarRequestTests {
    @Test func itNamesRoboAndSendsNothingElse() async throws {
        try await withTemp { (dir: URL) async throws in
            let f = fetcher(dir) { _ in .body(Data("BODY".utf8)) }
            #expect(try await f.fetch(arxiv) == Data("BODY".utf8))
            let sent = Stub.requests[0]
            #expect(sent.value(forHTTPHeaderField: "User-Agent") == "Robo/1.0 (personal study assistant)" && RadarFetcher.userAgent == "Robo/1.0 (personal study assistant)")
            #expect(sent.value(forHTTPHeaderField: "Cookie") == nil && sent.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(sent.value(forHTTPHeaderField: "If-None-Match") == nil && sent.httpMethod == "GET" && sent.httpBody == nil && RadarFetcher.timeout == 20)
        }
    }

    @Test func aRedirectToAnotherHostOrToHttpIsRefusedAndOneOnTheSameHostIsFollowed() async {
        await withTemp { dir in
            for (i, to) in ["https://evil.example.net/x", "https://huggingface.co/api/daily_papers", "http://rss.arxiv.org/atom/cs.CV", "https://rss.arxiv.org:8443/x"].enumerated() {
                let f = fetcher(dir.appendingPathComponent("\(i)")) { r in r.url?.path == "/atom/cs.CV" ? .redirect(to) : .body(Data("followed".utf8)) }
                #expect(await failure(f, arxiv) == .http(302), "\(to)")
                #expect(Stub.requests.map { $0.url?.absoluteString } == [arxiv.absoluteString], "\(to): the second request never went out")
            }
            let same = fetcher(dir.appendingPathComponent("same")) { r in r.url?.path == "/atom/cs.CV" ? .redirect("https://rss.arxiv.org/atom/other") : .body(Data("moved".utf8)) }
            #expect((try? await same.fetch(arxiv)) == Data("moved".utf8))
            #expect(Stub.requests.map { $0.url?.path } == ["/atom/cs.CV", "/atom/other"])
        }
    }

    @Test func aBodyOverTheCapIsRefusedAndTheCapsAreTheOnesOfTheBrief() async throws {
        #expect(RadarFetcher.defaultMaxBytes == 4_000_000 && RadarFetcher.caps == ["rss.arxiv.org": 8_000_000, "raw.githubusercontent.com": 24_000_000])
        try await withTemp { (dir: URL) async throws in
            let small = ["rss.arxiv.org": 2000]
            let f = fetcher(dir, caps: small, max: 1000) { _ in .body(Data(repeating: 65, count: 1001)) }
            #expect(await failure(f, URL(string: "https://huggingface.co/api/daily_papers")!) == .tooBig)  // the default cap, counted as it comes
            #expect((try? await f.fetch(arxiv))?.count == 1001)  // arXiv has its own, bigger one
            Stub.handler = { _ in .body(Data("x".utf8), headers: ["Content-Length": "2001"]) }
            #expect(await failure(f, arxiv) == .tooBig)  // announced: refused before reading
            Stub.handler = { _ in .body(Data(repeating: 65, count: 1000)) }
            #expect(try await f.fetch(URL(string: "https://ctftime.org/api/v1/events/")!).count == 1000)  // exactly the cap is fine
        }
    }
}

// MARK: - the cache

@Suite(.serialized) struct RadarCacheTests {
    private func cacheNames(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("radar-cache").path)) ?? []).sorted()
    }

    @Test func anEtagComesBackAsIfNoneMatchAndA304ServesTheCachedBodyEvenAfterARestart() async throws {
        try await withTemp { (dir: URL) async throws in
            let reply: (URLRequest) -> Stub.Reply = { r in
                r.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" ? .body(Data(), status: 304) : .body(Data("V1".utf8), headers: ["ETag": "\"v1\""])
            }
            let f = fetcher(dir, reply: reply)
            #expect(try await f.fetch(arxiv) == Data("V1".utf8))
            #expect(try await f.fetch(arxiv) == Data("V1".utf8))  // 304: the body comes from the disk
            #expect(Stub.requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } == [nil, "\"v1\""])
            let restarted = fetcher(dir, reply: reply)  // another run, another day: a new fetcher over the same folder
            #expect(try await restarted.fetch(arxiv) == Data("V1".utf8))
            #expect(Stub.requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } == ["\"v1\""])
            // a changed page replaces the cached one
            Stub.handler = { _ in .body(Data("V2".utf8), headers: ["ETag": "\"v2\""]) }
            #expect(try await restarted.fetch(arxiv) == Data("V2".utf8))
            Stub.handler = { r in r.value(forHTTPHeaderField: "If-None-Match") == "\"v2\"" ? .body(Data(), status: 304) : .body(Data("?".utf8)) }
            #expect(try await restarted.fetch(arxiv) == Data("V2".utf8))
        }
    }

    @Test func lastModifiedWorksWhenThereIsNoEtagAndAnAnswerWithNeitherKeepsNothing() async throws {
        try await withTemp { (dir: URL) async throws in
            let date = "Mon, 19 Oct 2026 04:00:00 GMT"
            let f = fetcher(dir) { r in
                r.value(forHTTPHeaderField: "If-Modified-Since") == date ? .body(Data(), status: 304) : .body(Data("L1".utf8), headers: ["Last-Modified": date])
            }
            #expect(try await f.fetch(arxiv) == Data("L1".utf8))
            #expect(try await f.fetch(arxiv) == Data("L1".utf8))
            #expect(Stub.requests.map { $0.value(forHTTPHeaderField: "If-Modified-Since") } == [nil, date])
            let plain = fetcher(dir) { _ in .body(Data("P".utf8)) }  // the same URL now answers with no validator: nothing is worth keeping
            #expect(try await plain.fetch(arxiv) == Data("P".utf8) && cacheNames(dir).isEmpty)
            #expect(Stub.requests[0].value(forHTTPHeaderField: "If-Modified-Since") == date)  // still asked with the old one, answered in full
            _ = try await plain.fetch(arxiv)
            #expect(Stub.requests[1].value(forHTTPHeaderField: "If-Modified-Since") == nil)
        }
    }

    @Test func aStrayNotModifiedWithNothingCachedIsAnError() async {
        await withTemp { dir in
            #expect(await failure(fetcher(dir) { _ in .body(Data(), status: 304) }, arxiv) == .http(304))
        }
    }

    @Test func noCacheFileNamesOrHoldsTheUrl() async throws {
        try await withTemp { (dir: URL) async throws in
            let url = URL(string: "https://rss.arxiv.org/atom/cs.CV?token=\(secret)")!
            let f = fetcher(dir, hosts: []) { _ in .body(Data("BODY".utf8), headers: ["ETag": "\"e\"", "Last-Modified": "Mon, 19 Oct 2026 04:00:00 GMT"]) }
            #expect(try await f.fetch(url) == Data("BODY".utf8))
            let folder = dir.appendingPathComponent("radar-cache")
            let names = cacheNames(dir)
            #expect(names.count == 2 && names.allSatisfy { $0.range(of: #"^[0-9a-f]{64}\.(body|json)$"#, options: .regularExpression) != nil }, "\(names)")
            for name in names {
                let text = String(decoding: try Data(contentsOf: folder.appendingPathComponent(name)), as: UTF8.self)
                for word in [secret, "arxiv", "https", "token", "atom"] { #expect(!text.contains(word), "\(name) holds \(word)") }
                #expect(mode(folder.appendingPathComponent(name)) == 0o600)
            }
            #expect(mode(folder) == 0o700)
            #expect(!names.joined().contains("arxiv"))
        }
    }

    @Test func aCacheNotAskedForInThirtyDaysIsForgotten() async throws {
        try await withTemp { dir in
            let f = fetcher(dir) { _ in .body(Data("A".utf8), headers: ["ETag": "\"a\""]) }
            _ = try await f.fetch(arxiv)
            _ = try await f.fetch(github)
            let folder = dir.appendingPathComponent("radar-cache")
            let old = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.path).first { $0.hasSuffix(".json") })
            let aged = Date().addingTimeInterval(-31 * 86_400)
            try FileManager.default.setAttributes([.modificationDate: aged], ofItemAtPath: folder.appendingPathComponent(old).path)
            _ = RadarFetcher(cacheDir: folder, now: { Date() })  // a new fetcher cleans up as it starts; the files' dates are the real ones
            let left = cacheNames(dir)
            #expect(left.count == 2 && !left.contains(old) && !left.contains(old.replacingOccurrences(of: ".json", with: ".body")), "\(left)")
        }
    }
}

// MARK: - failures, back-off, manners

@Suite(.serialized) struct RadarMannersTests {
    @Test func aFailureBacksTheSourceOffForAboutADayAndTheBackOffSurvivesARestart() async {
        await withTemp { dir in
            let time = Time()
            let f = fetcher(dir, time: time) { _ in .body(Data(), status: 503) }
            #expect(await failure(f, arxiv) == .http(503))
            #expect(Stub.requests.count == 1)
            #expect(await failure(f, arxiv) == .backedOff && Stub.requests.count == 1, "no second request")
            #expect(await failure(f, github) == .http(503) && Stub.requests.count == 2, "another source is not affected")
            time.move(19 * 3600)
            #expect(await failure(f, arxiv) == .backedOff && Stub.requests.count == 2)
            let again = fetcher(dir, time: time) { _ in .body(Data("fine".utf8)) }  // another launch, same day: still backed off
            #expect(await failure(again, arxiv) == .backedOff && Stub.requests.isEmpty)
            time.move(2 * 3600)  // 21 h: tomorrow's run is not skipped
            #expect((try? await again.fetch(arxiv)) == Data("fine".utf8) && Stub.requests.count == 1)
            #expect((try? await again.fetch(arxiv)) == Data("fine".utf8), "a good answer ends the back-off")
            #expect(RadarFetcher.backoff == 20 * 3600)
        }
    }

    @Test func noNetworkIsNotTheSourcesFaultSoItIsNotBackedOff() async {
        await withTemp { dir in
            for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .timedOut, .secureConnectionFailed] {
                let f = fetcher(dir) { _ in .fail(code) }
                let first = await failure(f, arxiv)
                #expect(first?.transient == true, "\(code)")
                #expect(await failure(f, arxiv) == first && Stub.requests.count == 2, "\(code): tried again at once")
            }
            #expect(await failure(fetcher(dir) { _ in .fail(.notConnectedToInternet) }, arxiv) == .offline)
            #expect(await failure(fetcher(dir) { _ in .fail(.timedOut) }, arxiv) == .timedOut)
        }
    }

    @Test func anErrorIsInFixedWordsAndNeverCarriesTheAddress() async {
        await withTemp { dir in
            let url = URL(string: "https://rss.arxiv.org/atom/cs.CV?token=\(secret)")!
            let cases: [(Stub.Reply, RadarFetchError, String)] = [
                (.body(Data(), status: 403), .http(403), "HTTP 403"), (.fail(.timedOut), .timedOut, "timed out"),
                (.fail(.notConnectedToInternet), .offline, "no connection"), (.fail(.badServerResponse), .failed(-1011), "network error (-1011)"),
            ]
            for (i, (reply, error, words)) in cases.enumerated() {
                let got = await failure(fetcher(dir.appendingPathComponent("\(i)")) { _ in reply }, url)  // a folder each: an error answer backs the source off
                #expect(got == error && got?.description == words, "\(words)")
                #expect(!"\(got!)".contains(secret) && !"\(got!)".contains("arxiv"))
            }
            #expect(RadarFetchError.notAllowed.transient == false && RadarFetchError.backedOff.transient == false && RadarFetchError.tooBig.transient == false)
        }
    }

    @Test func twoRequestsToOneHostStartAGapApartAndOtherHostsAreIndependent() async {
        await withTemp { dir in
            let time = Time()
            let f = fetcher(dir, time: time) { _ in .body(Data("x".utf8)) }
            for i in 0..<3 { _ = try? await f.fetch(URL(string: "https://rss.arxiv.org/atom/c\(i)")!) }
            #expect(time.waits == [3, 6], "arXiv: 3 s apart")
            let others = Time()
            let g = fetcher(dir, time: others) { _ in .body(Data("x".utf8)) }
            for i in 0..<3 { _ = try? await g.fetch(URL(string: "https://boards-api.greenhouse.io/v1/boards/b\(i)/jobs")!) }
            #expect(others.waits == [1, 2], "the rest: 1 s apart")
            #expect(RadarFetcher.gaps["rss.arxiv.org"] == 3 && RadarFetcher.defaultGap == 1)
            _ = try? await g.fetch(URL(string: "https://huggingface.co/api/daily_papers")!)
            _ = try? await g.fetch(URL(string: "https://ctftime.org/api/v1/events/")!)
            #expect(others.waits == [1, 2], "a first request to another host waits for nothing")
            others.move(10)
            _ = try? await g.fetch(URL(string: "https://boards-api.greenhouse.io/v1/boards/b9/jobs")!)
            #expect(others.waits == [1, 2], "and a request long after the last needs no wait either")
        }
    }

    @Test func requestsThatStartTogetherQueueUpOneGapAfterTheOther() async {
        await withTemp { dir in
            let time = Time()
            let f = fetcher(dir, time: time) { _ in .body(Data("x".utf8)) }
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<4 { group.addTask { _ = try? await f.fetch(URL(string: "https://rss.arxiv.org/atom/c\(i)")!) } }
            }
            #expect(time.waits == [3, 6, 9], "\(time.waits)")
            let hn = Time()
            let h = fetcher(dir, time: hn) { _ in .body(Data("x".utf8)) }
            for i in 0..<3 { _ = try? await h.fetch(URL(string: "https://hacker-news.firebaseio.com/v0/item/\(i).json")!) }
            #expect(hn.waits == [0.25, 0.5], "Hacker News: 30 stories fit in 15 s")
        }
    }
}

}  // RadarFetcherTests

// MARK: - radar.json

@Suite struct RadarFileTests {
    private func offer(_ id: String, until: Date) -> RadarOffer {
        RadarOffer(id: id, category: .digest, title: "5 picks for you today", detail: "A · B", note: "Radar/2026-10-20.md", until: until)
    }

    @Test func theRadarStateRoundTripsInAPrivateFileAndForgetsTheOldItems() async throws {
        try await withTemp { dir in
            let files = NudgeFiles(dir: dir)
            #expect(files.loadRadar(now: start) == RadarState() && files.radarFile.lastPathComponent == "radar.json")
            var state = RadarState()
            state.day = "2026-10-20"
            state.seen = ["arxiv:1": start, "old": start.addingTimeInterval(-61 * 86_400), "edge": start.addingTimeInterval(-59 * 86_400)]
            state.offers = [offer("radar-digest-2026-10-20", until: start.addingTimeInterval(3600))]
            #expect(files.save(state) && mode(files.radarFile) == 0o600 && mode(dir) == 0o700)
            let back = files.loadRadar(now: start)
            #expect(back.day == "2026-10-20" && back.seen.keys.sorted() == ["arxiv:1", "edge"] && back.offers == state.offers)
            #expect(back.offers[0].candidate == NudgeCandidate(id: "radar-digest-2026-10-20", category: .digest, title: "5 picks for you today", detail: "A · B",
                                                                note: "Radar/2026-10-20.md"))
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(left == ["radar.json"])  // no temp file left
        }
    }

    @Test func aMissingOrBrokenOrNewerFileReadsAsWhatItCan() async throws {
        try await withTemp { dir in
            let files = NudgeFiles(dir: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for junk in ["{ not json", "", "[]", "{\"day\": 5}", "{\"offers\": [{\"id\": 1}]}"] {
                try Data(junk.utf8).write(to: files.radarFile)
                #expect(files.loadRadar(now: start) == RadarState(), "\(junk)")
            }
            try Data("{\"day\": \"2026-10-20\"}".utf8).write(to: files.radarFile)  // an older file: the other fields are their defaults
            #expect(files.loadRadar(now: start).day == "2026-10-20" && files.loadRadar(now: start).seen.isEmpty)
        }
    }
}
