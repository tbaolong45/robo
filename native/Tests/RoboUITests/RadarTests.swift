// The daily radar, end to end: a fake downloader hands back fixture bodies for every source (so no test touches the network), the vault
// is a temp folder (so no test touches the real one), the wall clock is a fake (UTC, so 07:00 and the slots 09:00 / 13:00 / 19:00 are
// exact). `Radar.run` is driven directly for what a run finds and writes, and through the rig for when it runs and what the card does.
// 2026-10-20 is a Tuesday.
import AppKit
import Foundation
import Testing
import RoboCore
import RoboSystem
@testable import RoboUI

private let utc = TimeZone(identifier: "UTC")!

/// Seconds since 1970 of 2026-10-`day` at h:m UTC.
private func at(_ h: Int, _ m: Int = 0, day: Int = 20) -> Double {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc
    return cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!.timeIntervalSince1970
}

private func date(_ h: Int, _ m: Int = 0, day: Int = 20) -> Date { Date(timeIntervalSince1970: at(h, m, day: day)) }

private func iso(_ seconds: Double) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds)) }

// MARK: - the profile and the sources

private let profileText = """
    # Robo radar profile
    - interests: robotics*2, vision, medical imaging
    - goals: a research internship in robotics
    - country: Germany
    - arxivCategories: cs.CV, cs.RO
    - companies: greenhouse:acme
    - feeds: https://news.example.org/rss.xml
    - exclude: crypto
    """

private let arxivURL = "https://rss.arxiv.org/atom/cs.CV+cs.RO"
private let hfURL = "https://huggingface.co/api/daily_papers"
private let topURL = "https://hacker-news.firebaseio.com/v0/topstories.json"
private let feedURL = "https://news.example.org/rss.xml"
private let simplifyURL = "https://raw.githubusercontent.com/SimplifyJobs/Summer2027-Internships/dev/.github/scripts/listings.json"
private let acmeURL = "https://boards-api.greenhouse.io/v1/boards/acme/jobs"
private let ctfURL = "https://ctftime.org/api/v1/events/?limit=30"
private let codeforcesURL = "https://codeforces.com/api/contest.list?gym=false"
private func hnItem(_ id: Int) -> String { "https://hacker-news.firebaseio.com/v0/item/\(id).json" }
/// The seven blogs of labs and companies, and the three searches of the profile's strongest interests (robotics*2, vision, medical imaging).
private let announcementURLs = RadarHosts.announcements.map(\.link)
private let githubQueries = ["robotics", "vision", "medical imaging"]
private func githubURLs(_ when: Date = date(8)) -> [String] { githubQueries.map { Radar.githubSearch($0, now: when, zone: utc) } }
/// Every source of a full run of `profileText`: 11 as before, 7 announcement feeds and 3 GitHub searches.
private let sourcesOfAFullRun = 11 + 7 + 3

private func atom(_ entries: [(id: String, title: String, summary: String)]) -> String {
    "<?xml version='1.0' encoding='UTF-8'?><feed xmlns:arxiv=\"http://arxiv.org/schemas/atom\" xmlns=\"http://www.w3.org/2005/Atom\">"
        + entries.map {
            "<entry><id>oai:arXiv.org:\($0.id)v1</id><title>\($0.title)</title><link href=\"https://arxiv.org/abs/\($0.id)\" rel=\"alternate\" type=\"text/html\"/>"
                + "<summary>arXiv:\($0.id)v1 Announce Type: new\nAbstract: \($0.summary)</summary><category term=\"cs.RO\"/>"
                + "<published>\(iso(at(0)))</published><arxiv:announce_type>new</arxiv:announce_type></entry>"
        }.joined() + "</feed>"
}

private func story(_ id: Int, _ title: String, url: String, score: Int = 100) -> String {
    #"{"id":\#(id),"type":"story","title":"\#(title)","url":"\#(url)","score":\#(score),"time":\#(Int(at(6)))}"#
}

private func listing(_ company: String, _ title: String, url: String, places: [String], terms: String = "Summer 2027") -> String {
    let where_ = places.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"company_name":"\#(company)","title":"\#(title)","url":"\#(url)","locations":[\#(where_)],"active":true,"is_visible":true,"date_posted":\#(Int(at(5))),"terms":["\#(terms)"],"category":"Hardware"}"#
}

/// Fixture bodies for every source, as of `at(8)`: papers (one matching, one off-topic, one excluded word, one hostile), a daily-papers
/// list, three stories (one hostile), a feed, five SimplifyJobs listings, one company board, two CTFs and two Codeforces rounds.
private func serveEverything(_ f: RadarFakes) {
    f.serve(arxivURL, atom([
        ("2610.00001", "Robot arm calibration with vision", "We calibrate a robotics arm using vision."),
        ("2610.00002", "Medical imaging transformers", "A medical imaging model."),
        ("2610.00003", "A study of crypto tokens", "Crypto prices and robotics."),
        ("2610.00004", "&lt;b&gt;Robot&lt;/b&gt; [click](javascript:alert(1)) &lt;script&gt;alert(2)&lt;/script&gt;", "Robotics with a hostile title."),
    ]))
    f.serve(hfURL, #"[{"paper":{"id":"2610.00001","title":"Robot arm calibration with vision","summary":"x","upvotes":40,"publishedAt":"\#(iso(at(0)))"}},"#
        + #"{"paper":{"id":"2610.00005","title":"Vision for surgical robotics","summary":"Surgical robotics vision.","upvotes":12,"publishedAt":"\#(iso(at(0)))"}}]"#)
    f.serve(topURL, "[101,102,103]")
    f.serve(hnItem(101), story(101, "Show HN: A robotics simulator", url: "https://blog.example.com/sim"))
    f.serve(hnItem(102), story(102, "&lt;img src=x onerror=alert(1)&gt;", url: "javascript:alert(1)"))
    f.serve(hnItem(103), story(103, "Click [here](javascript:alert(2))", url: "javascript:alert(2)"))
    f.serve(feedURL, """
        <?xml version="1.0"?><rss version="2.0"><channel><title>News</title>
        <item><title>Medical imaging AI wins a prize</title><link>https://news.example.org/a</link><description>A medical imaging group won.</description>
        <pubDate>Tue, 20 Oct 2026 06:00:00 GMT</pubDate></item></channel></rss>
        """)
    f.serve(simplifyURL, "[" + [
        listing("Acme Robotics", "Robotics Research Intern", url: "https://careers.acmerobotics.com/jobs/1", places: ["Berlin, Germany"]),
        listing("Tokyo Vision", "Vision Intern", url: "https://apply.tokyovision.example/1", places: ["Tokyo, Japan"]),
        listing("Shady", "Robotics Intern", url: "https://totally-unrelated.example.net/apply", places: ["Remote"]),
        listing("Unknown Co", "Vision Intern", url: "https://jobs.lever.co/unknown/1", places: []),
        listing("Crypto Corp", "Crypto trading intern", url: "https://careers.cryptocorp.example/1", places: ["Berlin, Germany"]),
    ].joined(separator: ",") + "]")
    f.serve(acmeURL, #"{"jobs":[{"title":"Robotics Software Intern","absolute_url":"https://job-boards.greenhouse.io/acme/jobs/9","location":{"name":"Munich, Germany"},"#
        + #""updated_at":"\#(iso(at(7)))","application_deadline":"\#(iso(at(8) + 48 * 3600))"},{"title":"Senior Staff Engineer","absolute_url":"https://job-boards.greenhouse.io/acme/jobs/8","location":{"name":"Munich"}}]}"#)
    f.serve(ctfURL, #"[{"id":3451,"title":"Robotics CTF 2026","ctftime_url":"https://ctftime.org/event/3451","start":"2026-10-24T14:00:00+00:00","weight":25.5,"onsite":false,"format":"Jeopardy","restrictions":"Open","description":"Hack some robots."},"#
        + #"{"id":3452,"title":"Cooking Quiz Night","ctftime_url":"https://ctftime.org/event/3452","start":"2026-10-25T10:00:00+00:00","weight":0,"onsite":false,"format":"Jeopardy","restrictions":"Open","description":"x"}]"#)
    f.serve(codeforcesURL, #"{"status":"OK","result":[{"id":2100,"name":"Codeforces Round 1000 (Div. 2)","type":"CF","phase":"BEFORE","durationSeconds":7200,"startTimeSeconds":\#(Int(at(8)) + 3 * 86_400)},"#
        + #"{"id":2099,"name":"Old round","type":"CF","phase":"FINISHED","durationSeconds":7200,"startTimeSeconds":\#(Int(at(8)) - 86_400)}]}"#)
    // the labs' blogs: the first has one post that matches the profile and one that does not, the others are quiet
    for (i, link) in announcementURLs.enumerated() {
        f.serve(link, i == 0 ? """
            <?xml version="1.0"?><rss version="2.0"><channel><title>Lab</title>
            <item><title>Robotics foundation models for vision</title><link>https://openai.com/index/robotics-vision</link><description>A new robotics and vision model.</description>
            <pubDate>Tue, 20 Oct 2026 06:00:00 GMT</pubDate></item>
            <item><title>A new office in a faraway city</title><link>https://openai.com/index/office</link><description>We are opening an office.</description>
            <pubDate>Tue, 20 Oct 2026 05:00:00 GMT</pubDate></item></channel></rss>
            """ : #"<?xml version="1.0"?><rss version="2.0"><channel><title>Quiet</title></channel></rss>"#)
    }
    // GitHub: the search for "robotics" has a repository that matches and one that does not; the others find nothing
    for (i, link) in githubURLs().enumerated() {
        f.serve(link, i == 0 ? #"{"total_count":2,"items":[{"full_name":"acme/robot-arm-vision","description":"Vision-guided robotics arm control","stargazers_count":120,"#
            + #""created_at":"\#(iso(at(0)))","topics":["robotics","vision"],"language":"Python","fork":false,"archived":false},"#
            + #"{"full_name":"someone/todo-app","description":"A to-do list","stargazers_count":900,"created_at":"\#(iso(at(0)))","topics":[],"language":"Go"}]}"# : #"{"total_count":0,"items":[]}"#)
    }
}

private func vault() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("robo-radar-\(UUID().uuidString)")
}

/// How many items a note lists under the headings of `names` (an item is a `- [` line; an opportunity's sub-lines are not).
private func listed(_ text: String, _ names: [String]) -> Int {
    text.components(separatedBy: "\n## ").dropFirst().filter { section in names.contains { section.hasPrefix($0) } }
        .map { $0.split(separator: "\n").filter { $0.hasPrefix("- [") }.count }.reduce(0, +)
}

private func writeProfile(_ vault: URL, _ text: String) throws {
    let folder = vault.appendingPathComponent("Radar")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try text.write(to: folder.appendingPathComponent("Profile.md"), atomically: true, encoding: .utf8)
}

private func note(_ vault: URL, _ day: String = "2026-10-20") -> String? {
    try? String(contentsOf: vault.appendingPathComponent("Radar/\(day).md"), encoding: .utf8)
}

private func mode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)!.intValue & 0o7777
}

/// One run, as the window would start it.
private func run(_ vault: URL, _ f: RadarFakes, at when: Date = date(8), seen: [String: Date] = [:]) async -> RadarOutcome {
    await Radar.run(vault: vault, now: when, zone: utc, seen: seen, fetcher: { hosts in
        f.hosts = hosts
        return f
    })
}

// MARK: - what a run finds and writes

@Suite struct GitHubSearchTests {
    @Test func theSearchIsTheLastWeekMostStarredFirstAndNamesOnlyTheQuery() throws {
        let url = Radar.githubSearch("computer vision", now: date(8), zone: utc)
        #expect(url == "https://api.github.com/search/repositories?q=computer%20vision%20in:name,description,topics%20created:%3E2026-10-13%20stars:%3E10&sort=stars&order=desc&per_page=10")
        // decoded, it holds the query words and the fixed qualifiers, and nothing else of the profile
        let q = try #require(URLComponents(string: url)?.queryItems?.first { $0.name == "q" }?.value)
        #expect(q == "computer vision in:name,description,topics created:>2026-10-13 stars:>10")
        // a week back is the user's local day, not UTC's: 00:30 in Hanoi on the 20th is still the 19th in UTC
        let hanoi = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        #expect(Radar.githubSearch("x", now: date(17, 30, day: 19), zone: hanoi).contains("created:%3E2026-10-13"))  // 00:30 on the 20th there
        #expect(Radar.githubSearch("x", now: date(17, 30, day: 19), zone: utc).contains("created:%3E2026-10-12"))
    }
}

@Suite(.serialized) struct RadarRunTests {
    @Test func noProfileMakesTheTemplateOnceAndFetchesNothing() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        let f = RadarFakes()
        let found = await run(v, f)
        let file = v.appendingPathComponent("Radar/Profile.md")
        #expect(try String(contentsOf: file, encoding: .utf8) == Profile.template() && mode(file) == 0o644)
        #expect(found.done && f.asked.isEmpty && found.seen.isEmpty)
        #expect(found.offers.map(\.id) == ["radar-setup"] && found.offers[0].category == .digest && found.offers[0].note == "Radar/Profile.md")
        #expect(found.offers[0].title == "Tell me what you want to discover")
        #expect(found.offers[0].detail == "Fill in Radar/Profile.md (interests, goals...), I read it tomorrow morning")
        #expect(found.offers[0].until == date(8).addingTimeInterval(7 * 86_400))
        // the note is the user's: it is never written over, and a note with no interests is not an occasion for a second card
        try "my own words\n- interests:\n".write(to: file, atomically: true, encoding: .utf8)
        let again = await run(v, f, at: date(8, day: 21))
        #expect(try String(contentsOf: file, encoding: .utf8) == "my own words\n- interests:\n")
        #expect(again.done && again.offers.isEmpty && f.asked.isEmpty)
        let made = Radar.createProfile(at: file)  // and by itself
        let kept = try String(contentsOf: file, encoding: .utf8)
        let left = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).sorted()
        #expect(!made && kept == "my own words\n- interests:\n" && left == ["Profile.md"])  // no temp file left either
    }

    @Test func aProfileWithoutInterestsFetchesNothingAndWritesNothing() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        try writeProfile(v, "- interests:\n- arxivCategories: cs.CV\n- companies: greenhouse:acme\n")
        let f = RadarFakes()
        serveEverything(f)
        let found = await run(v, f)
        #expect(found.done && found.offers.isEmpty && found.seen.isEmpty && f.asked.isEmpty && note(v) == nil)
    }

    @Test func interestsFetchEverySourceRankAndWriteTheNote() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        try writeProfile(v, profileText)
        let f = RadarFakes()
        serveEverything(f)
        let found = await run(v, f)
        // every source once; only categories, a company, the profile's own feed and (for GitHub) the three strongest interests are in a URL
        #expect(f.asked.count == sourcesOfAFullRun)
        #expect(Set(f.asked) == Set([arxivURL, hfURL, topURL, hnItem(101), hnItem(102), hnItem(103), feedURL, simplifyURL, acmeURL, ctfURL, codeforcesURL]
            + announcementURLs + githubURLs()))
        // ...and never what else the profile says: not the goals, the country, the excluded words; GitHub gets the interests and nothing more
        for url in f.asked { for word in ["germany", "crypto", "research internship"] { #expect(!url.lowercased().contains(word), "\(url)") } }
        for url in f.asked where !url.hasPrefix("https://api.github.com/") { for word in ["robotic", "medical"] { #expect(!url.lowercased().contains(word), "\(url)") } }
        #expect(f.asked.filter { $0.hasPrefix("https://api.github.com/") }.count == 3)
        #expect(f.hosts == ["news.example.org"] && found.done && found.failed.isEmpty)

        let text = try #require(note(v))
        let heads = text.split(separator: "\n").filter { $0.hasPrefix("#") }.map(String.init)
        #expect(heads == ["# Radar · 2026-10-20", "## Papers", "## Announcements", "## News", "## Code", "## Opportunities", "## Contests"])
        let lines = Set(text.split(separator: "\n").map(String.init))
        for line in ["- [Robot arm calibration with vision](https://arxiv.org/abs/2610.00001) · arxiv.org · matches: robotics, vision · ✓ a primary source · a preprint: not peer reviewed",
                     "- [Medical imaging AI wins a prize](https://news.example.org/a) · news.example.org · matches: medical imaging",
                     "- [Acme Robotics — Robotics Research Intern](https://careers.acmerobotics.com/jobs/1) · careers.acmerobotics.com · matches: robotics · its address matches the employer's name (that does not prove the employer is real)",
                     "- [Robotics CTF 2026](https://ctftime.org/event/3451) · ctftime.org · matches: robotics · ✓ a primary source",
                     "- [Robotics foundation models for vision](https://openai.com/index/robotics-vision) · openai.com · matches: robotics, vision",
                     "- [acme/robot-arm-vision](https://github.com/acme/robot-arm-vision) · github.com · matches: robotics, vision · written by anyone: not checked by an editor",
                     "  - deadline: none stated", "  - deadline: 2026-10-22 08:00", "  - event start: 2026-10-24 14:00",
                     "  - eligibility unclear, check", "  - fits what you told Robo", RadarNote.standingLine] {
            #expect(lines.contains(line), "\(line)")
        }
        // what does not fit, or is excluded, or is over, or is not early-career, is not there
        for word in ["Tokyo Vision", "rypto", "Old round", "Senior Staff Engineer"] { #expect(!text.contains(word), "\(word)") }
        // and nothing that matches no interest of the profile is a paper, an announcement, news, code or an internship (the 2026-10-22 note
        // had four of five internships and a CSS article "outside your interests")
        for word in ["faraway city", "todo-app", "Shady"] { #expect(!text.contains(word), "\(word)") }
        let readingAndCode = text.components(separatedBy: "\n## Opportunities").first ?? ""
        #expect(!readingAndCode.contains("outside your interests"))

        // the digest is one offer with the real count and the first two titles; the best contest and a closing internship are their own
        let n = text.split(separator: "\n").filter { $0.hasPrefix("- [") }.count
        let titles = text.split(separator: "\n").filter { $0.hasPrefix("- [") }
            .compactMap { line in line.range(of: "](https://").map { String(line[line.index(line.startIndex, offsetBy: 3)..<$0.lowerBound]) } }
        let digest = try #require(found.offers.first { $0.category == .digest })
        let reads = listed(text, ["Papers", "Announcements", "News"]), looks = listed(text, ["Code", "Opportunities", "Contests"])
        #expect(reads > 0 && looks > 0 && reads + looks == n)
        #expect(digest.id == "radar-digest-2026-10-20" && digest.title == "\(reads) to read, \(looks) to look into" && digest.note == "Radar/2026-10-20.md" && digest.url == nil)
        #expect(digest.detail == titles.prefix(2).joined(separator: " · ") && n == 14 && found.seen.count == n && Set(found.seen).count == n)
        #expect(digest.title == "5 to read, 9 to look into")  // 3 papers, 1 announcement and 1 news item; 1 repository, 5 opportunities, 3 contests
        let contest = try #require(found.offers.first { $0.category == .contest })
        #expect(contest.id == "radar-contest-ctftime:3451" && contest.title == "Robotics CTF 2026" && contest.url == "https://ctftime.org/event/3451" && contest.note == nil)
        #expect(contest.dueAt == date(14, day: 24) && contest.detail.hasPrefix("starts ") && contest.detail.hasSuffix("ctftime.org"))
        let opp = try #require(found.offers.first { $0.category == .opportunity })
        #expect(opp.id == "radar-opp-https://job-boards.greenhouse.io/acme/jobs/9" && opp.url == "https://job-boards.greenhouse.io/acme/jobs/9")
        #expect(opp.dueAt == date(8).addingTimeInterval(48 * 3600) && opp.detail.hasPrefix("deadline ") && opp.detail.hasSuffix("job-boards.greenhouse.io"))
        #expect(found.offers.count == 3 && found.offers.allSatisfy { $0.until == date(0, day: 21) })  // a day-old offer is stale
        #expect(mode(v.appendingPathComponent("Radar/2026-10-20.md")) == 0o644)
    }

    @Test func aSourceThatFailsDoesNotBlockTheOthers() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        try writeProfile(v, profileText)
        let f = RadarFakes()
        serveEverything(f)
        f.fail(arxivURL, .http(500))
        f.fail(topURL, .timedOut)
        f.fail(ctfURL, .failed(-1011))
        let found = await run(v, f)
        let text = try #require(note(v))
        #expect(found.done && found.failed.sorted() == ["CTFtime: network error (-1011)", "Hacker News: timed out", "arXiv: HTTP 500"])
        #expect(text.contains("[Robot arm calibration with vision](https://arxiv.org/abs/2610.00001)"))  // the same paper, from Hugging Face
        #expect(!text.contains("Medical imaging transformers") && !text.contains("Robotics CTF 2026") && !text.contains("robotics simulator"))
        #expect(text.contains("Codeforces Round 1000") && text.contains("Medical imaging AI wins a prize") && text.contains("Robotics Research Intern"))
    }

    @Test func aDayWithNoNetworkWritesNothingKeepsNothingAndIsNotDone() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        try writeProfile(v, profileText)
        let f = RadarFakes()
        serveEverything(f)
        f.offline = true
        let found = await run(v, f)
        #expect(!found.done && found.offers.isEmpty && found.seen.isEmpty && note(v) == nil && !found.failed.isEmpty)
        #expect(f.asked.count >= 8)  // every source was tried
        // a day on which the sources answered with errors is done, though: it is their answer, and half an hour later would be the same.
        // (The hand-listed programmes need no source, so that day's note has only them.)
        let g = RadarFakes()
        let sick = await run(v, g)  // nothing served: every URL is a 404
        let text = try #require(note(v))
        #expect(sick.done && sick.failed.count >= 8 && sick.offers.map(\.category) == [.digest] && !text.contains("## Papers") && text.contains("## Opportunities"))
    }

    @Test func whatWasShownIsNeverShownAgain() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        try writeProfile(v, profileText)
        let f = RadarFakes()
        serveEverything(f)
        let first = await run(v, f)
        let firstNote = try #require(note(v))
        var seen: [String: Date] = [:]
        for id in first.seen { seen[id] = date(8) }
        let second = await run(v, f, at: date(8, day: 21), seen: seen)
        let nextNote = note(v, "2026-10-21") ?? ""
        #expect(Set(second.seen).isDisjoint(with: first.seen) && !second.offers.isEmpty)
        let before = firstNote.split(separator: "\n").filter { $0.hasPrefix("- [") }
        for line in before { #expect(!nextNote.contains(line), "\(line) came back") }
        #expect(second.seen.isEmpty == nextNote.isEmpty && !second.seen.isEmpty)  // a note only when something is new (the papers and news that missed the first cut are)
        // a posting that closes within 72 hours still nudges, though an earlier note had it: that is what the deadline is for
        #expect(second.offers.contains { $0.category == .opportunity && $0.id == "radar-opp-https://job-boards.greenhouse.io/acme/jobs/9" })
    }

    @Test func aRunThatFindsNothingNewWritesNoNoteAndOffersNoDigest() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        try writeProfile(v, "- interests: robotics\n")
        let f = RadarFakes()
        f.serve("https://rss.arxiv.org/atom/cs.AI+cs.LG", atom([("2610.00001", "A robotics paper", "robotics")]))  // the default categories
        let first = await run(v, f)
        #expect(first.offers.map(\.category) == [.digest] && note(v) != nil)
        var seen: [String: Date] = [:]
        for id in first.seen + Programmes.all.map(\.id) { seen[id] = date(8) }  // the programmes the first note left out, too
        let second = await run(v, f, at: date(8, day: 21), seen: seen)
        #expect(second.done && second.seen.isEmpty && second.offers.isEmpty && note(v, "2026-10-21") == nil)
    }

    @Test func theEligibilityOfYouDecidesWhatIsListedAndHowItIsLabelled() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        let f = RadarFakes()
        serveEverything(f)
        // in Germany: the Tokyo posting is outside what was said, the one with no place is unclear, the others fit
        try writeProfile(v, profileText)
        _ = await run(v, f)
        let text = try #require(note(v))
        #expect(!text.contains("Tokyo Vision"))
        let unclear = text.components(separatedBy: "\n").firstIndex { $0.contains("Unknown Co — Vision Intern") }
        let lines = text.components(separatedBy: "\n")
        #expect(unclear != nil && lines[unclear! + 2] == "  - eligibility unclear, check")
        // in Japan: the Tokyo one is the one that fits and the Berlin one is outside
        try writeProfile(v, profileText.replacingOccurrences(of: "Germany", with: "Japan"))
        try? FileManager.default.removeItem(at: v.appendingPathComponent("Radar/2026-10-20.md"))
        _ = await run(v, f)
        let japan = try #require(note(v))
        #expect(japan.contains("Tokyo Vision — Vision Intern") && !japan.contains("Acme Robotics — Robotics Research Intern"))
    }

    @Test func theStandingLineAndTheApplyWarningAreInTheNote() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        try writeProfile(v, profileText)
        let f = RadarFakes()
        serveEverything(f)
        _ = await run(v, f)
        let text = try #require(note(v))
        let lines = text.components(separatedBy: "\n")
        let heading = try #require(lines.firstIndex(of: "## Opportunities"))
        #expect(lines[heading + 2] == RadarNote.standingLine && lines.filter { $0 == RadarNote.standingLine }.count == 1)
        #expect(RadarNote.standingLine == "> Apply only through the employer's own page. Never pay to apply, and never send ID or bank details. Robo never applies for you.")
        // none for the employer's own site (Acme) or a known job board (Lever); the link that goes somewhere else (Shady) is below
        // the clean ones, so with five clean postings it is not among the five shown (the next test gives it room)
        #expect(!lines.contains { $0.contains("⚠") })
        // the contest section has no standing line and no apply warning
        let contests = try #require(lines.firstIndex(of: "## Contests"))
        #expect(!lines[contests...].contains { $0.contains("⚠") || $0 == RadarNote.standingLine })
    }

    /// What the source check does to a run: a clear scam is not in the note at all; a doubtful posting is, after the clean ones and with
    /// a ⚠ line for each of its first two reasons; and a doubtful posting that closes within 72 hours would have been a popup of its own,
    /// but a page that needs checking is not worth an interruption.
    @Test func aScamIsNotThereADoubtfulPostingComesLastAndNeverInterrupts() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        try writeProfile(v, "- interests: robotics*3\n- companies: greenhouse:acme\n")
        let f = RadarFakes()
        // the clean posting matches the profile worst, so by rank alone it would come last: only the source check puts it first
        f.serve(simplifyURL, "[" + [
            listing("Shady", "Robotics Intern", url: "https://totally-unrelated.example.net/apply", places: ["Remote"]),
            listing("Phish", "Robotics Intern", url: "https://login-microsoft.netlify.app/apply", places: ["Remote"]),
            listing("Acme Robotics", "Mechanical Design Intern", url: "https://careers.acmerobotics.com/jobs/1", places: ["Remote"]),
        ].joined(separator: ",") + "]")
        f.serve(acmeURL, #"{"jobs":[{"title":"Robotics Software Intern","absolute_url":"https://apply.acme-offers.pages.dev/9","location":{"name":"Remote"},"#
            + #""updated_at":"\#(iso(at(7)))","application_deadline":"\#(iso(at(8) + 48 * 3600))"}]}"#)
        var seen: [String: Date] = [:]
        for p in Programmes.all { seen[p.id] = date(8) }  // so the curated programmes do not fill the slots
        let found = await run(v, f, seen: seen)
        let text = try #require(note(v))
        #expect(!text.contains("login-microsoft") && !text.contains("Phish"))  // a clear scam: not in the note at all
        let lines = text.components(separatedBy: "\n")
        let clean = try #require(lines.firstIndex { $0.contains("Acme Robotics — Mechanical Design Intern") })
        let shady = try #require(lines.firstIndex { $0.contains("Shady — Robotics Intern") })
        let pages = try #require(lines.firstIndex { $0.contains("apply.acme-offers.pages.dev") })
        #expect(clean < shady && clean < pages)  // the clean one first
        #expect(lines[shady + 3].hasPrefix("  - ⚠ The apply link goes to totally-unrelated.example.net"))
        #expect(lines[pages + 3].hasPrefix("  - ⚠ A page on a hosting service") && lines.filter { $0.contains("⚠") }.count >= 3)
        // the posting on free hosting closes within 72 hours, matches the profile, and would be a popup: it is not
        #expect(!found.offers.contains { $0.category == .opportunity })
        #expect(found.offers.map(\.category) == [.digest])
        #expect(lines.contains(RadarNote.standingLine))
    }

    /// A contest whose text asks for a fee comes after the clean one in the note, though it starts first; and the digest popup does not name it.
    @Test func aDoubtfulContestComesLastAndTheDigestPopupDoesNotNameIt() async throws {
        func ctf(_ id: Int, _ title: String, start: String, description: String) -> String {
            #"{"id":\#(id),"title":"\#(title)","ctftime_url":"https://ctftime.org/event/\#(id)","start":"\#(start)","weight":25.5,"onsite":false,"format":"Jeopardy","restrictions":"Open","description":"\#(description)"}"#
        }
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        try writeProfile(v, "- interests: robotics\n")
        var seen: [String: Date] = [:]
        for p in Programmes.all { seen[p.id] = date(8) }
        let f = RadarFakes()
        f.serve(ctfURL, "[" + ctf(21, "Robotics clean CTF", start: "2026-10-26T14:00:00+00:00", description: "Hack some robots.") + ","
                + ctf(22, "Robotics fee CTF", start: "2026-10-23T14:00:00+00:00", description: "A registration fee of $10 applies.") + "]")
        let found = await run(v, f, seen: seen)
        let lines = try #require(note(v)).components(separatedBy: "\n")
        let clean = try #require(lines.firstIndex { $0.contains("Robotics clean CTF") })
        let fee = try #require(lines.firstIndex { $0.contains("Robotics fee CTF") })
        #expect(clean < fee, "the clean contest first, though the other starts earlier")
        #expect(lines.first { $0.contains("⚠") } != nil)
        let digest = try #require(found.offers.first { $0.category == .digest })
        #expect(digest.title == "2 to look into" && digest.detail == "Robotics clean CTF")  // the doubtful one is not advertised
        #expect(found.offers.first { $0.category == .contest }?.title == "Robotics clean CTF")  // and the popup is the clean one's
        // when every pick is in doubt the popup says so
        let g = RadarFakes()
        g.serve(ctfURL, "[" + ctf(22, "Robotics fee CTF", start: "2026-10-23T14:00:00+00:00", description: "A registration fee of $10 applies.") + "]")
        let alone = await run(v, g, at: date(8, day: 21), seen: seen)
        let digest2 = try #require(alone.offers.first { $0.category == .digest })
        #expect(digest2.detail == "Check the sources in the note: some need a closer look")
        #expect(!alone.offers.contains { $0.category == .contest })  // a doubtful contest is not a popup of its own
    }

    /// A story behind a shortened link is doubtful: it is not one of the news the digest picks, a clean one is.
    @Test func aDoubtfulStoryIsNotPickedForTheDigest() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        try writeProfile(v, "- interests: robotics\n")
        var seen: [String: Date] = [:]
        for p in Programmes.all { seen[p.id] = date(8) }
        let f = RadarFakes()
        f.serve(topURL, "[101,102]")
        f.serve(hnItem(101), story(101, "Robotics simulator tour", url: "https://bit.ly/3robosim", score: 900))
        f.serve(hnItem(102), story(102, "Robotics arm teardown", url: "https://blog.example.com/arm", score: 50))
        _ = await run(v, f, seen: seen)
        let text = try #require(note(v))
        #expect(text.contains("Robotics arm teardown") && !text.contains("Robotics simulator tour"), "\(text)")
    }

    @Test func aCleanPostingThatClosesSoonIsStillAPopup() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        try writeProfile(v, "- interests: robotics\n- companies: greenhouse:acme\n")
        let f = RadarFakes()
        serveEverything(f)
        let found = await run(v, f)
        #expect(found.offers.contains { $0.category == .opportunity })  // the guard against the test above passing for the wrong reason
    }

    @Test func hostileTitlesAndLinksNeverBecomeLinksOrMarkup() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        try writeProfile(v, "- interests: robotics\n- arxivCategories: cs.RO\n- feeds: https://news.example.org/rss.xml\n")
        let f = RadarFakes()
        f.serve("https://rss.arxiv.org/atom/cs.RO", atom([
            ("2610.00004", "&lt;b&gt;Robot&lt;/b&gt; [click](javascript:alert(1)) &lt;script&gt;alert(2)&lt;/script&gt;robotics",
             "robotics ![x](https://evil.example/pixel.png) &lt;img src=https://evil.example/p.png&gt;"),
            ("2610.00006", "[[wikilink]] %% comment %% # heading $$m$$ ==hi== |t| ~~s~~ `code` *em* _u_ robotics", "robotics"),
            ("2610.00007", "Link](https://evil.example/x) and https://evil.example/bare robotics", "robotics"),
        ]))
        f.serve(topURL, "[201,202]")
        f.serve(hnItem(201), story(201, "Click [here](javascript:alert(2)) robotics", url: "javascript:alert(2)"))
        f.serve(hnItem(202), story(202, "robotics &lt;img src=x onerror=alert(1)&gt;", url: "data:text/html,<script>alert(1)</script>"))
        f.serve(feedURL, """
            <?xml version="1.0"?><rss version="2.0"><channel><title>News</title>
            <item><title>robotics &lt;a href="javascript:alert(3)"&gt;x&lt;/a&gt;</title><link>javascript:alert(3)</link></item>
            <item><title>robotics ok</title><link>https://news.example.org/ok</link><description>&lt;script&gt;alert(4)&lt;/script&gt;visible</description></item>
            </channel></rss>
            """)
        f.serve(simplifyURL, "[" + [
            listing("Evil", "Robotics Intern </a><b>x</b>", url: "javascript:alert(1)", places: ["Remote"]),
            listing("Evil2", "Robotics Intern](https://evil.example/steal)", url: "https://evil2.example/apply?x=1&y=(2)&z=%20", places: ["Remote"]),
        ].joined(separator: ",") + "]")
        _ = await run(v, f)
        let text = try #require(note(v))
        let lines = text.components(separatedBy: "\n")
        // every line is a heading, the standing line, a bullet or a sub-bullet: no title started a block of its own
        for line in lines where !line.isEmpty {
            let ok = line.hasPrefix("# Radar · ") || line.hasPrefix("## ") || line == RadarNote.standingLine || line.hasPrefix("- [") || line.hasPrefix("  - ")
            #expect(ok, "\(line)")
        }
        // every link target is https, and every https:// in the note is one (a bare address in a title is broken so that it is no link)
        let targets = try NSRegularExpression(pattern: #"(?<!\\)\]\(([^)]*)\)"#).matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range(at: 1), in: text)!]) }
        #expect(targets.count >= 6 && targets.allSatisfy { $0.hasPrefix("https://") && !$0.contains(" ") }, "\(targets)")
        #expect(text.components(separatedBy: "https://").count - 1 == targets.count, "a bare https:// in a title")
        for line in lines where line.hasPrefix("- [") {
            #expect(line.range(of: #"(?<!\\)[<>]"#, options: .regularExpression) == nil, "\(line)")  // no tag
            #expect(!line.contains("![") && !line.contains("[[") && !line.contains("%%") && !line.contains("==") && !line.contains("$$"), "\(line)")
        }
        #expect(text.contains(#"\[click\](javascript:alert(1))"#) && !text.contains("<script") && !text.contains("<img") && !text.contains("</a>"))
        #expect(!text.contains("alert(3)") && !text.contains("alert(4)") && !text.contains("data:text"))  // dropped with their entry or their markup
        #expect(text.contains("Evil2") && text.contains("https://evil2.example/apply?x=1&y=%282%29&z=%20"))  // a link target cannot end early
    }

    @Test func hackerNewsStoriesAreFetchedSixAtATimeAndAllOfThem() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        try writeProfile(v, "- interests: robotics\n")
        let f = RadarFakes()
        f.serve(topURL, "[" + (1...40).map(String.init).joined(separator: ",") + "]")  // 40 are listed, 30 are used
        for id in 1...40 { f.serve(hnItem(id), story(id, "Story \(id) about robotics", url: "https://blog.example.com/\(id)")) }
        f.delay = .milliseconds(40)
        f.watch = "/v0/item/"
        _ = await run(v, f)
        let stories = f.asked.filter { $0.contains("/v0/item/") }
        #expect(stories.count == 30 && Set(stories).count == 30 && stories.contains(hnItem(30)) && !stories.contains(hnItem(31)))
        #expect(f.most > 1 && f.most <= 6, "\(f.most) at once")
    }

    @Test func hackerNewsStopsAtItsClockWhileStoriesAreStillComing() async throws {
        let f = RadarFakes()
        f.serve(topURL, "[" + (1...10).map(String.init).joined(separator: ",") + "]")
        for id in 1...10 { f.serve(hnItem(id), story(id, "Story \(id) about robotics", url: "https://blog.example.com/\(id)")) }
        f.delay = .seconds(2)  // every story is slower than the clock
        let items = try await Radar.hackerNews(f, seconds: 0.3)
        #expect(items.isEmpty)  // what had come by then, which was nothing, and no crash
    }

    @Test func onlyHttpsFeedsOfANamedHostAreAllowedToTheDownloader() async throws {
        let v = vault()
        defer { try? FileManager.default.removeItem(at: v) }
        try writeProfile(v, "- interests: robotics\n- feeds: https://News.Example.org/a.xml, http://plain.example.org/b.xml, https://192.168.0.7/c.xml, https://printer.local/d.xml, https://www.example.net/e.xml\n")
        let f = RadarFakes()
        _ = await run(v, f)
        #expect(f.hosts == ["news.example.org", "www.example.net"])
        let feeds = f.asked.filter { $0.lowercased().contains("example.") || $0.contains("192.168") || $0.contains("printer") }
        #expect(feeds.count == 2 && feeds.allSatisfy { $0.hasSuffix("/a.xml") || $0.hasSuffix("/e.xml") }, "\(feeds)")  // the other three were never asked
    }

    @Test func theSimplifyRepositoryOfTheSeasonAndTheNotesThatOpen() {
        func year(_ month: Int, _ y: Int = 2026) -> Int {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = utc
            return Radar.simplifyYear(cal.date(from: DateComponents(year: y, month: month, day: 15))!, zone: utc)
        }
        #expect(year(1) == 2026 && year(7) == 2026 && year(8) == 2027 && year(10) == 2027 && year(12) == 2027 && year(1, 2027) == 2027)
        let v = URL(fileURLWithPath: "/tmp/vault")
        #expect(Radar.noteURL("Radar/2026-10-20.md", vault: v)?.path == "/tmp/vault/Radar/2026-10-20.md")
        #expect(Radar.noteURL("Radar/Profile.md", vault: v)?.path == "/tmp/vault/Radar/Profile.md")
        for bad in ["", "Radar", "Radar/", "../x.md", "Radar/../x.md", "Radar/..md", "/etc/passwd", "/tmp/vault/Radar/x.md", "Radar/x.txt", "Radar/.hidden.md",
                    "Notes/x.md", "Radar/a/b.md", "Radar//x.md", "radar/x.md", "Radar/x.md/", "Radar/x y.md", "Radar/x\u{0}.md"] {
            #expect(Radar.noteURL(bad, vault: v) == nil, "\(bad)")
        }
    }
}

// MARK: - the note's words

@Suite struct RadarNoteTests {
    private func item(_ title: String = "T", url: String = "https://a.example/x") -> RadarItem {
        RadarItem(kind: .paper, title: title, url: url, source: "S", trust: 0.5)!
    }

    @Test func textIsEscapedForMarkdownAndObsidian() {
        #expect(RadarNote.escape("Plain words, numbers 1.5 and Q-learning.") == "Plain words, numbers 1.5 and Q-learning.")
        for special in ["\\", "`", "*", "_", "[", "]", "<", ">", "#", "~", "=", "$", "%", "|"] {
            #expect(RadarNote.escape("a\(special)b") == "a\\\(special)b", "\(special)")
        }
        #expect(RadarNote.escape("see https://evil.example/x and http://a.b") == #"see https\://evil.example/x and http\://a.b"#)
        #expect(RadarNote.escape("[click](javascript:alert(1))") == #"\[click\](javascript:alert(1))"#)
    }

    @Test func aLinkTargetCannotEndEarlyOrCarryMarkup() {
        #expect(RadarNote.target("https://x.example/a_(b)c d?q=<1>\"'`\\") == "https://x.example/a_%28b%29c%20d?q=%3C1%3E%22%27%60%5C")
        #expect(RadarNote.target("https://x.example/ü?q=ok") == "https://x.example/ü?q=ok")
    }

    @Test func theDigestSaysWhatIsToReadAndWhatIsToLookIntoAndLeavesOutAnEmptyHalf() {
        var picks = RadarNote.Picks()
        picks.papers = [item("A short paper")]
        let one = RadarNote.digestOffer(picks, day: "2026-10-20", until: date(0, day: 21))
        #expect(one.title == "1 to read" && one.detail == "A short paper" && one.note == "Radar/2026-10-20.md" && one.category == .digest)
        picks.news = [item(String(repeating: "long ", count: 40)), item("third")]
        let several = RadarNote.digestOffer(picks, day: "2026-10-20", until: date(0, day: 21))
        #expect(several.title == "3 to read" && several.detail.hasPrefix("A short paper · long long") && several.detail.hasSuffix("…"))
        #expect(several.detail.count < 100)  // two titles, cut: the card stays small
        picks.opportunities = [item("An internship")]
        picks.contests = [item("A contest"), item("Another contest")]
        #expect(RadarNote.digestOffer(picks, day: "2026-10-20", until: date(0, day: 21)).title == "3 to read, 3 to look into")
        picks.papers = []
        picks.news = []
        #expect(RadarNote.digestOffer(picks, day: "2026-10-20", until: date(0, day: 21)).title == "3 to look into")
    }

    @Test func aDeadlineIsInTheUsersZoneAndNoneStatedIsSaid() {
        let due = RadarItem(kind: .internship, title: "I", url: "https://a.example/x", source: "S", deadline: date(8, day: 22), trust: 0.5)!
        let open = RadarItem(kind: .internship, title: "I", url: "https://a.example/y", source: "S", trust: 0.5)!
        let event = RadarItem(kind: .contest, title: "C", url: "https://a.example/z", source: "S", deadline: date(14, day: 24), deadlineNote: "event start", trust: 0.5)!
        #expect(RadarNote.deadline(due, zone: utc) == "deadline: 2026-10-22 08:00" && RadarNote.deadline(open, zone: utc) == "deadline: none stated")
        #expect(RadarNote.deadline(due, zone: TimeZone(identifier: "Asia/Tokyo")!) == "deadline: 2026-10-22 17:00")
        #expect(RadarNote.deadline(event, zone: utc) == "event start: 2026-10-24 14:00")
    }
}

// MARK: - when it runs and what the card does

@MainActor private func launch(profile: String? = profileText, wall: Double = at(8), serve: Bool = true) async -> Rig {
    let r = Rig(radar: true)
    r.fake.wall = wall
    if let profile { try? writeProfile(r.vault, profile) }
    if serve { serveEverything(r.radarFake) }
    #expect(await pump(r.window.radar.started))
    return r
}

/// What the tick that runs every 30 s would do at wall time `wall`.
@MainActor private func tick(_ r: Rig, _ wall: Double) {
    r.fake.wall = wall
    r.window.nudgeTick()
}

/// The run that was started has come back.
@MainActor private func finished(_ r: Rig, day: String = "2026-10-20") async -> Bool {
    await pump(r.window.radar.state.day == day && !r.window.radar.running)
}

@MainActor private func files(_ r: Rig) -> NudgeFiles { NudgeFiles(dir: r.nudgeDir) }

@MainActor @Suite(.serialized) struct RadarWindowTests {
    @Test func withoutAProfileTheTemplateIsMadeAndOneCardAsksForIt() async throws {
        let r = await launch(profile: nil)
        defer { r.close() }
        tick(r, at(8))
        #expect(await finished(r))
        let file = r.vault.appendingPathComponent("Radar/Profile.md")
        #expect(try String(contentsOf: file, encoding: .utf8) == Profile.template() && r.radarFake.asked.isEmpty)
        #expect(r.window.radar.state.offers.map(\.id) == ["radar-setup"] && files(r).loadRadar(now: date(8)).offers.map(\.id) == ["radar-setup"])
        tick(r, at(9))
        let w: RoboWindow = r.window
        #expect(w.nudge.shown.map(\.candidate.id) == ["radar-setup"] && !w.card.isHidden)
        #expect(w.card.nudge.label.text == "WORTH A LOOK ▸" && !w.card.nudge.open.isHidden && w.mind.emotion == "curious")
        #expect(w.card.nudge.well.text == "Tell me what you want to discover\nFill in Radar/Profile.md (interests, goals...), I read it tomorrow morning")
        // Open shows the note in Obsidian (in front): no link, no alert
        w.card.nudge.open.onClick?()
        #expect(r.notes.map(\.url.path) == [file.path] && r.notes.map(\.front) == [true] && r.linkAsks.isEmpty && r.openedLinks.isEmpty)
        #expect(w.card.isHidden && w.nudge.shown.isEmpty)
        tick(r, at(13))
        #expect(w.nudge.shown.isEmpty)  // asked once
    }

    @Test func theRunStartsAtSevenOnceADayAndAgainTomorrow() async {
        let r = await launch(wall: at(6, 59))
        defer { r.close() }
        tick(r, at(6, 59))
        #expect(!r.window.radar.running && r.radarFake.asked.isEmpty && r.window.radar.state.day == "")
        tick(r, at(7))
        #expect(await finished(r) && r.radarFake.asked.count == sourcesOfAFullRun && note(r.vault) != nil)
        for t in [at(7, 1), at(10), at(18)] { tick(r, t) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(r.radarFake.asked.count == sourcesOfAFullRun, "one run a day")
        r.window.nudge = NudgeModel()  // a restart the same day
        r.window.startNudges()
        tick(r, at(12))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(r.radarFake.asked.count == sourcesOfAFullRun && r.window.radar.state.day == "2026-10-20")
        r.radarFake.forget()
        tick(r, at(6, 59, day: 21))
        #expect(!r.window.radar.running && r.radarFake.asked.isEmpty)
        tick(r, at(7, day: 21))
        #expect(await finished(r, day: "2026-10-21") && r.radarFake.asked.count == sourcesOfAFullRun)
    }

    @Test func whatTheNoteListedIsRememberedAcrossDaysAndRestarts() async throws {
        let r = await launch()
        defer { r.close() }
        tick(r, at(8))
        #expect(await finished(r))
        let first = try #require(note(r.vault))
        let listed = first.split(separator: "\n").filter { $0.hasPrefix("- [") }
        let seen = files(r).loadRadar(now: date(8)).seen
        #expect(listed.count == 14 && seen.count == 14 && seen.values.allSatisfy { $0 == date(8) })
        r.window.nudge = NudgeModel()  // the app is closed and opened again
        r.window.radar = RadarModel()
        r.window.startNudges()
        tick(r, at(7, day: 21))
        #expect(await finished(r, day: "2026-10-21"))
        let second = note(r.vault, "2026-10-21") ?? ""
        #expect(!second.isEmpty)  // the papers and news that missed the first cut
        for line in listed { #expect(!second.contains(line), "\(line) came back") }
        #expect(files(r).loadRadar(now: date(7, day: 21)).seen.count > 13)  // and they are remembered too
    }

    @Test func aRunThatFoundNothingNewIsStillTheDaysRun() async {
        let r = await launch(profile: "- interests: robotics\n", serve: false)  // every source answers 404; the programmes are all seen
        defer { r.close() }
        for p in Programmes.all { r.window.radar.state.seen[p.id] = date(7) }
        tick(r, at(8))
        #expect(await finished(r) && note(r.vault) == nil && r.window.radar.state.offers.isEmpty)
        let asked = r.radarFake.asked.count
        #expect(asked == 6 + 7 + 1)  // arXiv, Hugging Face, the Hacker News list, SimplifyJobs, CTFtime, Codeforces; the 7 blogs; 1 GitHub search
        for t in [at(8, 1), at(9), at(10)] { tick(r, t) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!r.window.radar.running && r.radarFake.asked.count == asked, "the day's run happened, with or without a note")
    }

    @Test func launchingLaterInTheDayRunsAtOnce() async {
        let r = await launch(wall: at(14))
        defer { r.close() }
        tick(r, at(14))
        #expect(await finished(r) && note(r.vault) != nil)
    }

    @Test func todaysNoteThatExistsAlreadyMeansTheRunIsDone() async throws {
        let r = await launch(wall: at(8))
        defer { r.close() }
        try FileManager.default.createDirectory(at: r.vault.appendingPathComponent("Radar"), withIntermediateDirectories: true)
        try "mine".write(to: r.vault.appendingPathComponent("Radar/2026-10-20.md"), atomically: true, encoding: .utf8)
        tick(r, at(8))
        #expect(!r.window.radar.running && r.window.radar.state.day == "2026-10-20" && r.radarFake.asked.isEmpty)
        #expect(files(r).loadRadar(now: date(8)).day == "2026-10-20")
        #expect(note(r.vault) == "mine")
    }

    @Test func nudgesTurnedOffFetchNothingUntilTheyAreTurnedOn() async {
        let r = await launch()
        defer { r.close() }
        r.window.menu(.nudges)
        #expect(!r.window.nudge.state.enabled)
        tick(r, at(8))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!r.window.radar.running && r.radarFake.asked.isEmpty && r.window.radar.state.day == "" && note(r.vault) == nil)
        r.window.menu(.nudges)
        tick(r, at(8, 1))
        #expect(await finished(r) && r.radarFake.asked.count == sourcesOfAFullRun)
    }

    @Test func aDayWithNoNetworkShowsNothingAndTriesAgainInHalfAnHour() async {
        let r = await launch()
        defer { r.close() }
        r.radarFake.offline = true
        tick(r, at(8, 45))
        #expect(await pump(r.window.radar.retryAt > 0 && !r.window.radar.running))
        let w: RoboWindow = r.window
        #expect(w.radar.state.day == "" && w.radar.state.offers.isEmpty && note(r.vault) == nil && w.radar.retryAt == at(8, 45) + 1800)
        r.radarFake.offline = false
        r.radarFake.forget()
        tick(r, at(9))  // the slot is open, and there is nothing to show; the network is back but it is not time to try again
        #expect(w.nudge.shown.isEmpty && w.card.isHidden && !w.radar.running && r.radarFake.asked.isEmpty)
        tick(r, at(9, 14))
        #expect(!w.radar.running && r.radarFake.asked.isEmpty)
        tick(r, at(9, 15))
        #expect(await finished(r) && note(r.vault) != nil)
    }

    @Test func oneRunAtATime() async {
        let r = await launch()
        defer { r.close() }
        r.radarFake.delay = .milliseconds(80)
        tick(r, at(8))
        tick(r, at(8, 1))
        #expect(await finished(r))
        #expect(r.radarFake.asked.filter { $0 == arxivURL }.count == 1)
    }

    @Test func theSlotsShowAnOpportunityThenTheDigestThenTheContestOnePerSlot() async throws {
        let r = await launch()
        defer { r.close() }
        tick(r, at(8))
        #expect(await finished(r))
        let w: RoboWindow = r.window
        let text = try #require(note(r.vault))
        let n = text.split(separator: "\n").filter { $0.hasPrefix("- [") }.count
        #expect(w.radar.state.offers.count == 3 && w.nudge.shown.isEmpty && w.card.isHidden)  // the run shows nothing by itself
        // 09:00: the internship that closes within 72 hours (its link asks first, like any link)
        tick(r, at(9))
        #expect(w.nudge.shown.map(\.candidate.category) == [.opportunity])
        #expect(w.card.nudge.well.text.hasPrefix("acme — Robotics Software Intern\ndeadline Thu 08:00 · job-boards.greenhouse.io\n↗ job-boards.greenhouse.io"))
        w.card.nudge.open.onClick?()
        #expect(r.linkAsks.map(\.absoluteString) == ["https://job-boards.greenhouse.io/acme/jobs/9"] && r.notes.isEmpty && w.card.isHidden)
        // 13:00: the digest, which opens the note
        tick(r, at(13))
        #expect(w.nudge.shown.map(\.candidate.id) == ["radar-digest-2026-10-20"])
        #expect(w.card.nudge.label.text == "WORTH A LOOK ▸" && w.card.nudge.well.text.hasPrefix("\(listed(text, ["Papers", "Announcements", "News"])) to read, \(listed(text, ["Code", "Opportunities", "Contests"])) to look into\n") && !w.card.nudge.open.isHidden)
        let digestTitles = w.card.nudge.well.text.components(separatedBy: "\n")[1]
        #expect(digestTitles.contains(" · ") && !w.card.nudge.well.text.contains("↗"))  // two titles, and no domain line
        w.card.nudge.open.onClick?()
        #expect(r.notes.map(\.url.path) == [r.vault.appendingPathComponent("Radar/2026-10-20.md").path] && r.notes.map(\.front) == [true])
        #expect(r.openedLinks.count == 1 && r.linkAsks.count == 1)  // the note went through no link alert and no browser
        // 19:00: the contest
        tick(r, at(19))
        #expect(w.nudge.shown.map(\.candidate.category) == [.contest] && w.card.nudge.well.text.hasPrefix("Robotics CTF 2026\nstarts Sat 14:00 · ctftime.org"))
        w.closeBubble()
        let state = files(r).loadNudges()
        #expect(state.sentToday == 3 && state.slotsUsed == [9, 13, 19] && state.sentByCategory == ["opportunity": 1, "digest": 1, "contest": 1])
        // a radar offer stands for no reminder: nothing of it is in reminders.json
        #expect(files(r).loadFired(now: date(19)).keys.keys.allSatisfy { !$0.hasPrefix("radar") })
    }

    @Test func notForMeOnTheDigestIsTheOrdinaryAnswer() async throws {
        let r = await launch()
        defer { r.close() }
        tick(r, at(8))
        #expect(await finished(r))
        let w: RoboWindow = r.window
        tick(r, at(9))
        w.card.nudge.later.onClick?()  // the internship, later: the next slot would bring it back
        tick(r, at(13))
        #expect(w.nudge.shown.map(\.candidate.category) == [.opportunity])  // back (it sorts before the digest)
        w.card.nudge.notForMe.onClick?()
        tick(r, at(19))
        #expect(w.nudge.shown.map(\.candidate.category) == [.digest])
        let id = w.nudge.shown[0].candidate.id
        w.card.nudge.notForMe.onClick?()
        let state = files(r).loadNudges()
        #expect(state.mutedUntil[id] == date(19).addingTimeInterval(30 * 86_400) && state.notForMeStreak["digest"] == 1 && state.shown[id] == nil)
        #expect(r.notes.isEmpty && w.card.isHidden)
    }

    @Test func theOffersOfTheDaySurviveARestartAndAreStaleAtMidnight() async throws {
        let r = await launch()
        defer { r.close() }
        tick(r, at(8))
        #expect(await finished(r))
        let w: RoboWindow = r.window
        w.nudge = NudgeModel()  // the app is closed and opened between the run and the slot
        w.radar = RadarModel()
        w.startNudges()
        #expect(w.radar.started && w.radar.state.offers.count == 3 && w.radar.state.day == "2026-10-20")
        #expect(await pump(!w.nudge.refreshing))
        tick(r, at(9))
        #expect(w.nudge.shown.count == 1)
        w.closeBubble()
        #expect(w.radarCandidates(Date(timeIntervalSince1970: at(23, 59))).count == 2)  // the shown one is not offered again
        #expect(w.radarCandidates(date(0, day: 21)).isEmpty)  // and what was not shown is stale at midnight
    }

    @Test func theSetupCardWaitsAWeekForASlot() async {
        let r = await launch(profile: nil)
        defer { r.close() }
        tick(r, at(8))
        #expect(await finished(r))
        #expect(r.window.radarCandidates(date(23, 59, day: 26)).map(\.id) == ["radar-setup"])
        #expect(r.window.radarCandidates(date(8, day: 27)).isEmpty)
    }

    @Test func aDigestWaitsForAFreeCardLikeEveryNudge() async {
        let r = await launch()
        defer { r.close() }
        tick(r, at(8))
        #expect(await finished(r))
        r.window.say("hello")  // a card is up
        tick(r, at(9))
        #expect(r.window.nudge.shown.isEmpty)
        r.window.closeBubble()
        tick(r, at(9, 1))
        #expect(r.window.nudge.shown.count == 1)
    }

    @Test func theDevSwitchLetsTheFirstRunIgnoreTheDayAndTheHourAndNothingElse() async {
        func switched(_ value: String?) -> Bool {
            Machine(home: FileManager.default.temporaryDirectory, environment: value.map { ["ROBO_RADAR_NOW": $0] } ?? [:]).radarNow
        }
        #expect(switched("1") && !switched(nil) && !switched("0") && !switched("yes") && !switched(""))
        let r = await launch(wall: at(3))
        defer { r.close() }
        r.window.radar.force = true  // what Machine's radarNow sets at launch
        tick(r, at(3))
        #expect(await finished(r) && r.radarFake.asked.count == sourcesOfAFullRun)
        r.radarFake.forget()
        tick(r, at(3, 1))
        tick(r, at(5, day: 21))  // the first run used the switch up: the ordinary rules are back
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!r.window.radar.running && r.radarFake.asked.isEmpty)
        tick(r, at(7, day: 21))
        #expect(await finished(r, day: "2026-10-21"))
    }

    @Test(arguments: ["../../etc/passwd", "Radar/../../x.md", "/Applications/Evil.app", "Notes/x.md"])
    func aNoteOutsideTheRadarFolderIsNeverOpened(_ evil: String) async {
        let r = await launch(profile: nil)
        defer { r.close() }
        let w: RoboWindow = r.window
        w.radar.state.day = "2026-10-20"  // today's run is done: only the offer below is there
        w.radar.state.offers = [RadarOffer(id: "evil", category: .digest, title: "t", detail: "d", note: evil, until: date(23))]
        tick(r, at(9))
        #expect(w.nudge.shown.count == 1 && !w.card.nudge.open.isHidden)  // the card offers it...
        w.card.nudge.open.onClick?()
        #expect(r.notes.isEmpty && r.openedLinks.isEmpty && w.nudge.shown.count == 1 && !w.card.isHidden, "\(evil)")  // ...and opens nothing
    }

    @Test func theRadarIsOffUnlessTheRigTurnsItOn() async {
        let r = Rig()
        defer { r.close() }
        r.fake.wall = at(8)
        #expect(await pump(r.window.nudge.started))
        tick(r, at(8))
        tick(r, at(9))
        #expect(!r.window.radar.running && r.radarFake.asked.isEmpty && !FileManager.default.fileExists(atPath: r.vault.path) && r.window.nudge.shown.isEmpty)
    }
}

// MARK: - the card for a note

@Suite struct RadarCardTests {
    @Test func aCandidateWithANoteCanBeOpenedAndShowsNoDomain() {
        let note = NudgeCandidate(id: "radar-digest-2026-10-20", category: .digest, title: "3 to read, 2 to look into", detail: "A · B", url: nil, note: "Radar/2026-10-20.md")
        let text = NudgeText([note])
        #expect(text.canOpen && text.domain == nil && text.label == "WORTH A LOOK ▸" && text.body == "3 to read, 2 to look into\nA · B")
        var plain = note
        plain.note = nil
        #expect(!NudgeText([plain]).canOpen)  // no link, no note
        plain.url = "http://insecure.example/x"
        #expect(!NudgeText([plain]).canOpen)
        plain.url = "https://paper.example/x"
        #expect(NudgeText([plain]).canOpen && NudgeText([plain]).domain == "paper.example")
        #expect(NudgeCandidate(id: "x", category: .digest, title: "t").note == nil)  // the other candidates are as they were
    }
}
