// The daily radar: once a day robo looks for papers, news, internships and programmes, hackathons and contests that fit what you wrote in
// `Radar/Profile.md` of your Obsidian vault, writes the picks to `Radar/YYYY-MM-DD.md`, and offers them on its card as a nudge. The
// pure parts are in RoboCore (`Feeds`, `Rank`, `Profile`, `NudgeBudget`) and the downloads in RoboSystem (`RadarFetcher`); this is the
// window's side of them:
//   - at the first tick after 07:00 local (or at launch, later in the day) when today's run has not happened, one run starts off the
//     main thread. `ROBO_RADAR_NOW=1` (a test copy) lets the first run after launch ignore the day and the hour.
//   - no note `Profile.md` yet: robo writes the template (never over an existing note) and offers ONE card that asks you to fill it in.
//     No interests in it: nothing is fetched.
//   - with interests every source is fetched on its own (one that fails never blocks the others), ranked with the profile, and the
//     note is written when there is something new. Everything robo shows once is remembered 60 days (`radar.json`), so a digest never
//     repeats. A run that finds nothing new writes no note.
//   - what the run offers (the digest; the best matching contest; a matching internship whose deadline is within 72 hours) goes into
//     the SAME candidate list as the calendar nudges: `NudgeBudget` decides when a card shows (slots, 3 a day, quiet hours, held
//     conditions, `enabled`). There is no second scheduler for showing.
//   - robo reads public pages. It never applies, signs in, pays or sends anything for you, and nothing from the profile leaves the Mac:
//     a source only learns the Mac's address and which category, company or feed is watched.
//   - every item goes through `SourceCheck` (offline: the address and the wording, no request): a clear scam never reaches the note, a doubtful
//     one comes last with a ⚠ line and is never a popup of its own, a primary source is marked ✓ and a preprint "not peer reviewed".
import AppKit
import RoboCore
import RoboSystem
import os

/// Everything the window keeps about the radar.
struct RadarModel {
    var state = RadarState()  // radar.json
    var started = false  // the file is read: nothing runs before that
    var running = false  // a run is in flight (one at a time)
    var retryAt = 0.0  // wall seconds: a run that could not reach the network tries again then
    var force = false  // ROBO_RADAR_NOW: the first run ignores the day and the hour
}

/// What one run brought, made off the main thread.
struct RadarOutcome: Sendable {
    /// false: nothing could be reached (the network was not there), so nothing is kept and the run is tried again later.
    var done = true
    var offers: [RadarOffer] = []
    /// The ids of everything the note shows: never shown again.
    var seen: [String] = []
    /// Why a source failed ("arXiv: HTTP 503"), in fixed words, for the log.
    var failed: [String] = []
}

enum Radar {
    static let log = Logger(subsystem: "ai.robo", category: "radar")
    static let hour = 7  // the daily run starts at the first tick after 07:00, local time
    static let retryS = 30.0 * 60  // after a run that could not reach the network
    static let setupDays = 7.0  // the "fill in your profile" card waits this long for a free slot
    static let hackerNewsStories = 30, hackerNewsParallel = 6, hackerNewsSeconds = 15.0
    static let opportunityHours = NudgeBudget.opportunityHours

    // MARK: time and files

    static func calendar(_ zone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    static func dayKey(_ date: Date, zone: TimeZone) -> String {
        let c = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func minutes(_ date: Date, zone: TimeZone) -> Int {
        let c = calendar(zone).dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func folder(_ vault: URL) -> URL { vault.appendingPathComponent("Radar", isDirectory: true) }

    /// A note of the radar from the path a candidate carries ("Radar/2026-10-20.md", relative to the vault): nothing else is opened.
    static func noteURL(_ relative: String, vault: URL) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Radar", !parts[1].contains(".."),
              parts[1].range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\.md$"#, options: .regularExpression) != nil else { return nil }
        return folder(vault).appendingPathComponent(String(parts[1]))
    }

    /// The profile note's text; nil when there is no note (an unreadable one reads as empty). At most 200 KB are read.
    static func readProfile(_ file: URL) -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        return String(decoding: (try? handle.read(upToCount: 200_000)) ?? Data(), as: UTF8.self)
    }

    /// Writes the template as a new note, never over an existing one: a temp file in the same folder is linked into place, which
    /// fails when the note is there. 0644 like the vault's other notes. false when it was not made.
    static func createProfile(at file: URL) -> Bool {
        let fm = FileManager.default
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".Profile.\(UUID().uuidString.prefix(8)).tmp")
        guard (try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
              fm.createFile(atPath: tmp.path, contents: Data(Profile.template().utf8), attributes: [.posixPermissions: 0o644]) else { return false }
        defer { unlink(tmp.path) }
        return link(tmp.path, file.path) == 0
    }

    static func setupOffer(now: Date) -> RadarOffer {
        RadarOffer(id: "radar-setup", category: .digest, title: "Tell me what you want to discover",
                   detail: "Fill in Radar/Profile.md (interests, goals...), I read it tomorrow morning", note: "Radar/Profile.md",
                   until: now.addingTimeInterval(setupDays * 86_400))
    }

    // MARK: the run

    /// One run, whatever the window thinks: the profile note, the sources, the ranking, the note, what is offered. `fetcher` makes the
    /// downloader once the profile has said which feed hosts it allows.
    static func run(vault: URL, now: Date, zone: TimeZone, seen: [String: Date], fetcher make: (Set<String>) -> RadarFetching) async -> RadarOutcome {
        let file = folder(vault).appendingPathComponent("Profile.md")
        guard let text = readProfile(file) else { return createProfile(at: file) ? RadarOutcome(offers: [setupOffer(now: now)]) : RadarOutcome() }
        let profile = Profile.parse(markdown: text)
        guard !profile.interests.isEmpty else { return RadarOutcome() }

        let found = await gather(jobs(profile, make(Set(profile.feeds.compactMap(RadarHosts.userHost))), now: now, zone: zone))
        var out = RadarOutcome(failed: found.failures.map { "\($0.name): \($0.error)" })
        if found.answered == 0, found.failures.allSatisfy({ $0.error.transient }) {
            out.done = false
            return out
        }

        // The source check (SourceCheck, offline): an item with a strong scam signal is dropped (only its host is logged); a doubtful one stays
        // for opportunities, after the clean ones and with its reasons in the note, but is never a popup of its own; doubtful news and papers
        // are left out of the digest, where they would only take a slot.
        let checked = (found.items + Programmes.all).map { ($0, SourceCheck.assess($0)) }
        let unsafe = checked.filter { $0.1.hidden }
        if !unsafe.isEmpty { log.notice("hid \(unsafe.count, privacy: .public) unsafe item(s) from: \(unsafe.map { $0.0.host }.joined(separator: ", "), privacy: .public)") }
        let doubtful = Set(checked.filter { $0.1.level == .doubtful }.map { $0.0.id })
        let pool = checked.filter { !$0.1.hidden }.map(\.0)
        func cleanFirst(_ ranked: [Rank.Ranked]) -> [Rank.Ranked] { ranked.filter { !doubtful.contains($0.item.id) } + ranked.filter { doubtful.contains($0.item.id) } }
        let taken = Set(seen.keys)
        func fits(_ item: RadarItem) -> Bool { profile.eligibility(for: item) != .excluded }
        let opportunities = cleanFirst(Rank.rank(pool.filter { ($0.kind == .internship || $0.kind == .program) && fits($0) }, profile: profile, now: now))
        let contests = cleanFirst(Rank.rank(pool.filter { ($0.kind == .contest || $0.kind == .hackathon) && fits($0) }, profile: profile, now: now))
        let digest = Rank.digest(items: pool.filter { !doubtful.contains($0.id) }, profile: profile, now: now, seen: taken)
        var picks = RadarNote.Picks()
        picks.papers = digest.filter { $0.kind == .paper }
        picks.news = digest.filter { $0.kind == .news }
        picks.opportunities = opportunities.filter { !taken.contains($0.item.id) }.prefix(5).map(\.item)
        func soonest(_ a: RadarItem, _ b: RadarItem) -> Bool { (a.deadline ?? .distantFuture) < (b.deadline ?? .distantFuture) }
        let three = contests.filter { !taken.contains($0.item.id) }.prefix(3).map(\.item)
        picks.contests = three.filter { !doubtful.contains($0.id) }.sorted(by: soonest) + three.filter { doubtful.contains($0.id) }.sorted(by: soonest)  // the next one first, doubtful ones last

        let day = dayKey(now, zone: zone)
        let cal = calendar(zone)
        let until = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)  // a day-old offer is stale
        if !picks.all.isEmpty {
            let note = folder(vault).appendingPathComponent(day + ".md")
            do {
                try FileManager.default.createDirectory(at: folder(vault), withIntermediateDirectories: true)
                try Data(RadarNote.markdown(day: day, picks: picks, profile: profile, zone: zone).utf8).write(to: note, options: .atomic)
                out.offers.append(RadarNote.digestOffer(picks, day: day, until: until, flagged: doubtful))
                out.seen = picks.all.map(\.id)
            } catch {
                log.warning("could not write today's radar note")  // nothing counts as shown: tomorrow's run finds the same items
            }
        }
        // The best matching contest to come, and a matching internship that closes within 72 hours, are nudges of their own (the
        // budget caps them). They come from everything ranked, shown in an earlier note or not: that is what the deadline is for.
        let soon = now.addingTimeInterval(opportunityHours * 3600)
        if let best = contests.first(where: { !$0.matched.isEmpty && ($0.item.deadline ?? .distantPast) > now && !doubtful.contains($0.item.id) }) {
            out.offers.append(RadarNote.offer(best.item, id: "radar-contest-", category: .contest, label: "starts", profile: profile, now: now, zone: zone, until: until))
        }
        if let best = opportunities.first(where: { !$0.matched.isEmpty && ($0.item.deadline ?? .distantPast) > now && ($0.item.deadline ?? .distantFuture) <= soon && !doubtful.contains($0.item.id) }) {
            out.offers.append(RadarNote.offer(best.item, id: "radar-opp-", category: .opportunity, label: "deadline", profile: profile, now: now, zone: zone, until: until))
        }
        return out
    }

    // MARK: the sources

    struct Job: Sendable {
        let name: String
        let run: @Sendable () async throws -> [RadarItem]
    }

    struct Gathered {
        var items: [RadarItem] = []
        var failures: [(name: String, error: RadarFetchError)] = []
        var answered = 0
    }

    /// The year of the SimplifyJobs repository that is current: from August on, next summer's.
    static func simplifyYear(_ now: Date, zone: TimeZone) -> Int {
        let c = calendar(zone).dateComponents([.year, .month], from: now)
        return (c.year ?? 2026) + ((c.month ?? 1) >= 8 ? 1 : 0)
    }

    /// What to ask, and how to read it. Only the profile's categories, companies and feeds are in a URL; nothing else of it.
    static func jobs(_ profile: Profile, _ fetch: RadarFetching, now: Date, zone: TimeZone) -> [Job] {
        var out: [Job] = []
        func add(_ name: String, _ link: String, _ parse: @escaping @Sendable (Data) -> [RadarItem]) {
            guard let url = URL(string: link) else { return }
            out.append(Job(name: name, run: { parse(try await fetch.fetch(url)) }))
        }
        if !profile.arxivCategories.isEmpty {
            add("arXiv", "https://rss.arxiv.org/atom/" + profile.arxivCategories.joined(separator: "+"), { Feeds.arxiv($0) })
        }
        add("Hugging Face", "https://huggingface.co/api/daily_papers", { Feeds.huggingFacePapers($0) })
        out.append(Job(name: "Hacker News", run: { try await hackerNews(fetch) }))
        for feed in profile.feeds {
            guard let host = RadarHosts.userHost(feed) else { continue }
            let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            add("feed " + name, feed, { Feeds.news($0, source: name) })
        }
        add("SimplifyJobs", "https://raw.githubusercontent.com/SimplifyJobs/Summer\(simplifyYear(now, zone: zone))-Internships/dev/.github/scripts/listings.json", { Feeds.simplify($0) })
        for company in profile.companies {
            let token = company.token
            switch company.board {
            case .greenhouse: add("Greenhouse \(token)", "https://boards-api.greenhouse.io/v1/boards/\(token)/jobs", { Feeds.greenhouse($0, company: token) })
            case .lever: add("Lever \(token)", "https://api.lever.co/v0/postings/\(token)?mode=json", { Feeds.lever($0, company: token) })
            case .ashby: add("Ashby \(token)", "https://api.ashbyhq.com/posting-api/job-board/\(token)", { Feeds.ashby($0, company: token) })
            }
        }
        add("CTFtime", "https://ctftime.org/api/v1/events/?limit=30", { Feeds.ctftime($0) })
        add("Codeforces", "https://codeforces.com/api/contest.list?gym=false", { Feeds.codeforces($0) })
        return out
    }

    /// Hacker News: the top stories' ids, then each story (the ids are all the list gives), at most 6 requests at a time and 15 seconds
    /// for all of them; what has come by then is used. One story that fails costs only itself.
    static func hackerNews(_ fetch: RadarFetching, seconds: Double = hackerNewsSeconds) async throws -> [RadarItem] {
        guard let top = URL(string: "https://hacker-news.firebaseio.com/v0/topstories.json") else { return [] }
        let ids = Feeds.hackerNewsIDs(try await fetch.fetch(top), limit: hackerNewsStories)
        return await withTaskGroup(of: [RadarItem]?.self, returning: [RadarItem].self) { group in
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil  // the clock: time is up
            }
            var items: [RadarItem] = []
            var next = 0, flying = 0
            while true {
                while flying < hackerNewsParallel, next < ids.count {
                    let id = ids[next]
                    next += 1
                    flying += 1
                    group.addTask {
                        guard let url = URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json"), let body = try? await fetch.fetch(url) else { return [] }
                        return Feeds.hackerNews(body)
                    }
                }
                guard flying > 0, let answer = await group.next(), let got = answer else { break }  // none left, or the clock
                flying -= 1
                items += got
            }
            group.cancelAll()
            return items
        }
    }

    /// Every job at once (the downloader paces requests to one host itself), each on its own: the items in the order of the jobs, so
    /// the ranking does not depend on which source was faster.
    struct Answer: Sendable {
        let index: Int, name: String
        let items: [RadarItem]?  // nil: the source failed with `error`
        let error: RadarFetchError?
    }

    /// The group hands its answers back through `returning:` and a plain struct. The first version collected them into a captured var
    /// from `for await`, with a tuple holding a `Result`: the debug build and every test were fine, the release build (Swift 6.4)
    /// lost every answer, and the app then crashed in `TaskGroup::offer` (found live 2026-10-20). Test concurrency code in release too.
    static func gather(_ jobs: [Job]) async -> Gathered {
        let answers = await withTaskGroup(of: Answer.self, returning: [Answer].self) { group in
            for (i, job) in jobs.enumerated() {
                group.addTask {
                    do { return Answer(index: i, name: job.name, items: try await job.run(), error: nil) } catch {
                        return Answer(index: i, name: job.name, items: nil, error: (error as? RadarFetchError) ?? .failed(0))
                    }
                }
            }
            var all: [Answer] = []
            while let answer = await group.next() { all.append(answer) }
            return all
        }
        var out = Gathered()
        for answer in answers.sorted(by: { $0.index < $1.index }) {
            if let items = answer.items {
                out.items += items
                out.answered += 1
            } else if let error = answer.error {
                out.failures.append((answer.name, error))
            }
        }
        return out
    }
}

// MARK: - the note

/// The vault note of a day: Obsidian Markdown, built from items that are already plain text and https (`RadarItem`), and escaped once
/// more here so that no title can become markup, a link or a comment.
enum RadarNote {
    static let standingLine = "> Apply only through the employer's own page. Never pay to apply, and never send ID or bank details. Robo never applies for you."

    struct Picks {
        var papers: [RadarItem] = [], news: [RadarItem] = [], opportunities: [RadarItem] = [], contests: [RadarItem] = []
        var all: [RadarItem] { papers + news + opportunities + contests }
    }

    static func markdown(day: String, picks: Picks, profile: Profile, zone: TimeZone) -> String {
        var out = ["# Radar · \(day)"]
        func section(_ title: String, _ items: [RadarItem], intro: String? = nil) {
            guard !items.isEmpty else { return }
            out += ["", "## \(title)", ""]
            if let intro { out += [intro, ""] }
            for item in items { out += lines(item, profile: profile, zone: zone) }
        }
        section("Papers", picks.papers)
        section("News", picks.news)
        section("Opportunities", picks.opportunities, intro: standingLine)
        section("Contests", picks.contests)
        return out.joined(separator: "\n") + "\n"
    }

    /// `[title](link) · where · why · what is known of the source`; an opportunity adds its deadline ("none stated" is said) and who it fits;
    /// anything the source check finds doubtful (for an internship also an apply link that is neither the employer's nor a known job board)
    /// gets a ⚠ line for each of its first two reasons.
    static func lines(_ item: RadarItem, profile: Profile, zone: TimeZone) -> [String] {
        let verdict = SourceCheck.assess(item)
        var head = "- [\(escape(item.title))](\(target(item.url))) · \(escape(item.host)) · \(escape(Rank.why(item: item, profile: profile)))"
        if let known = trust(verdict) { head += " · " + escape(known) }
        var out = [head]
        if item.isOpportunity {
            out.append("  - \(deadline(item, zone: zone))")
            var fit = profile.eligibility(for: item).note
            if let says = item.eligibility { fit += " (the listing says: \(says))" }
            out.append("  - \(escape(fit))")
        }
        if verdict.warns { out += verdict.reasons.prefix(2).map { "  - ⚠ \(escape($0))" } }
        return out
    }

    /// What the source check knows that is good or worth knowing: "✓ a primary source · a preprint: not peer reviewed", "written by anyone: ...".
    /// Nothing for a source that is doubtful (its ⚠ lines say it) or one about which there is nothing to say.
    static func trust(_ v: SourceCheck.Verdict) -> String? {
        guard !v.warns, !v.notes.isEmpty else { return nil }
        return (v.level == .official ? "✓ " : "") + v.notes.joined(separator: " · ")
    }

    static func deadline(_ item: RadarItem, zone: TimeZone) -> String {
        guard let due = item.deadline else { return "deadline: " + escape(item.deadlineNote ?? "none stated") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(escape(item.deadlineNote ?? "deadline")): \(f.string(from: due))"
    }

    /// Plain text into Markdown: a backslash before every character that Markdown or Obsidian would read as markup (brackets, tags,
    /// emphasis, code, comments `%%`, math `$`, highlights `==`, tables `|`, headings `#`), and before the colon of `://`, so that
    /// an address inside a title is not turned into a link either.
    static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\`*_[]<>#~=$%|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out.replacingOccurrences(of: "://", with: "\\://")
    }

    /// A link target that no character of the URL can end early or turn into markup.
    static func target(_ url: String) -> String {
        var out = ""
        for ch in url {
            if "()<>\\`\" '".contains(ch) { out += ch.utf8.map { String(format: "%%%02X", $0) }.joined() } else { out.append(ch) }
        }
        return out
    }

    static func short(_ text: String, _ max: Int) -> String { text.count > max ? String(text.prefix(max - 1)) + "…" : text }

    /// The digest as a nudge: how much there is to read (papers, news) and to look into (opportunities, contests), and the first two
    /// titles. A half with nothing in it is left out. Open shows the note.
    /// The titles it names are those of items whose source is not in doubt (a popup does not advertise a page that needs checking); when
    /// every pick is in doubt it says so instead.
    static func digestOffer(_ picks: Picks, day: String, until: Date, flagged: Set<String> = []) -> RadarOffer {
        let reads = picks.papers.count + picks.news.count, looks = picks.opportunities.count + picks.contests.count
        let title = [reads > 0 ? "\(reads) to read" : nil, looks > 0 ? "\(looks) to look into" : nil].compactMap { $0 }.joined(separator: ", ")
        let named = picks.all.filter { !flagged.contains($0.id) }.prefix(2).map { short($0.title, 70) }.joined(separator: " · ")
        return RadarOffer(id: "radar-digest-\(day)", category: .digest, title: title,
                          detail: named.isEmpty && !picks.all.isEmpty ? "Check the sources in the note: some need a closer look" : named, note: "Radar/\(day).md", until: until)
    }

    /// One contest or internship as a nudge of its own: when it starts or closes, where, and whether it fits. Open opens its page.
    static func offer(_ item: RadarItem, id: String, category: NudgeCategory, label: String, profile: Profile, now: Date, zone: TimeZone,
                      until: Date) -> RadarOffer {
        var detail = ["\(label) " + (item.deadline.map { Nudges.whenText($0, now: now, zone: zone) } ?? "soon"), item.host]
        if profile.eligibility(for: item) == .unclear { detail.append("eligibility unclear, check") }
        return RadarOffer(id: id + item.id, category: category, title: short(item.title, 120), detail: detail.joined(separator: " · "), url: item.url,
                          dueAt: item.deadline, until: until)
    }
}

// MARK: - the window's side

extension RoboWindow {
    /// At launch, once the files are read.
    func loadRadar(_ files: NudgeFiles, _ now: Date) {
        radar.state = files.loadRadar(now: now)
        radar.force = machine.radarNow
        radar.started = true
    }

    /// From `nudgeTick` (every 30 s of wall time): start the day's run when it is due. Nudges turned off, or a run in flight, or a
    /// run that found no network a moment ago, start nothing.
    func radarTick(_ now: Date, wall: Double) {
        guard machine.radarOn, radar.started, !radar.running, nudge.state.enabled, wall >= radar.retryAt else { return }
        let zone = machine.zone, day = Radar.dayKey(now, zone: zone)
        if !radar.force {
            guard radar.state.day != day, Radar.minutes(now, zone: zone) >= Radar.hour * 60 else { return }
            if FileManager.default.fileExists(atPath: Radar.folder(machine.vaultDir).appendingPathComponent(day + ".md").path) {
                radar.state.day = day  // today's digest is there already: the file outlived what radar.json forgot
                nudgeFiles.save(radar.state)
                return
            }
        }
        radar.force = false
        radar.running = true
        let (vault, seen, make, cache, bridge) = (machine.vaultDir, radar.state.seen, machine.radarFetcher,
                                                   machine.nudgeDir.appendingPathComponent("radar-cache"), bridge)
        Task.detached(priority: .utility) {
            let found = await Radar.run(vault: vault, now: now, zone: zone, seen: seen, fetcher: { make(cache, $0) })
            bridge.radar(found, day: day)
        }
    }

    /// The run is back: keep what it found. A run that reached nothing keeps nothing and tries again in half an hour.
    func onRadar(_ found: RadarOutcome, day: String) {
        radar.running = false
        if !found.failed.isEmpty { Radar.log.notice("radar sources failed: \(found.failed.joined(separator: "; "), privacy: .public)") }
        guard found.done else {
            radar.retryAt = machine.wall() + Radar.retryS
            Radar.log.notice("radar found no connection, trying again in 30 minutes")
            return
        }
        let now = wallDate, fresh = Set(found.offers.map(\.id))
        radar.state.day = day
        for id in found.seen { radar.state.seen[id] = now }
        radar.state.offers = radar.state.offers.filter { $0.until > now && !fresh.contains($0.id) } + found.offers
        nudgeFiles.save(radar.state)
    }

    /// What waits for a slot: the offers of the day (or the "fill in your profile" one) that were not shown yet.
    func radarCandidates(_ now: Date) -> [NudgeCandidate] {
        guard machine.radarOn else { return [] }
        return radar.state.offers.filter { $0.until > now && nudge.state.shown[$0.id] == nil }.map(\.candidate)
    }
}
