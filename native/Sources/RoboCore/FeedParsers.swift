// One pure parser per radar source: `(Data) -> [RadarItem]`. They never crash on junk (bad bytes, wrong types, giant
// fields, deep nesting) and drop any entry without a title or an https URL. Nothing here touches the network or a clock:
// the fetcher (RoboSystem) hands the bytes in. XML is parsed as a stream (SAX) and stops at a cap, because an arXiv feed
// holds a whole mailing; a document with a DOCTYPE or ENTITY declaration is rejected before parsing (entity bombs).
// Every source's shape was checked against one real sample on 2026-10-20 (arXiv, Hugging Face, Hacker News, MIT News RSS,
// Rust blog Atom, SimplifyJobs, Greenhouse, Ashby, CTFtime, Codeforces); Lever's was read from its docs (the sample cut off
// before `categories`).
import Foundation

public enum Feeds {
    static let maxXML = 8_000_000
    static let maxJSON = 32_000_000
    public static let arxivCap = 400

    // MARK: arXiv

    /// `rss.arxiv.org/atom/<cats>`: the mailing's new papers (`arxiv:announce_type` "new", or absent). Replacements
    /// ("replace", "replace-cross") and cross-lists ("cross") are dropped: a cross-listed paper is new in its own category's
    /// feed. The id comes from the abs link, the authors are dropped, the summary loses its "Announce Type / Abstract:" lead.
    public static func arxiv(_ data: Data) -> [RadarItem] {
        entries(data, limit: arxivCap).compactMap { e in
            let announced = e.fields["arxiv:announce_type"]?.lowercased()
            guard announced == nil || announced == "new" else { return nil }
            let fromLink = e.fields["link"].flatMap(Plain.https).map(Plain.key).flatMap { $0.hasPrefix("arxiv:") ? String($0.dropFirst(6)) : nil }
            guard let id = fromLink ?? e.fields["id"].flatMap(Plain.arxivID(from:)) else { return nil }
            let summary = (e.fields["summary"] ?? e.fields["description"] ?? "")
                .replacingOccurrences(of: #"^\s*arXiv:\S+\s+Announce Type:\s*\S+\s*(?:Abstract:\s*)?"#, with: "", options: .regularExpression)
            return RadarItem(id: "arxiv:" + id, kind: .paper, title: e.fields["title"] ?? "", url: "https://arxiv.org/abs/" + id,
                             source: "arXiv", snippet: summary,
                             published: When.parse(e.fields["published"] ?? e.fields["pubDate"] ?? e.fields["updated"]),
                             tags: e.categories, trust: 0.85)
        }
    }

    // MARK: Hugging Face daily papers

    /// `huggingface.co/api/daily_papers`: upvotes are the popularity, `ai_summary` (else the abstract) the snippet, the
    /// keywords the tags; a linked GitHub repo adds the tag "code". The link is the paper's arXiv page, and the id is the
    /// arXiv id, so the same paper from the arXiv feed is one item.
    public static func huggingFacePapers(_ data: Data) -> [RadarItem] {
        Array(list(json(data)).lazy.compactMap { e -> RadarItem? in
            guard let p = e["paper"] as? [String: Any], let id = str(p, "id").flatMap(Plain.arxivID(from:)) else { return nil }
            let code = str(p, "githubRepo") != nil || (num(p, "githubStars") ?? 0) > 0
            return RadarItem(id: "arxiv:" + id, kind: .paper, title: str(p, "title") ?? str(e, "title") ?? "",
                             url: "https://arxiv.org/abs/" + id, source: "Hugging Face",
                             snippet: str(p, "ai_summary") ?? str(p, "summary") ?? str(e, "summary") ?? "",
                             published: When.parse(str(p, "publishedAt") ?? str(e, "publishedAt")), popularity: num(p, "upvotes"),
                             tags: Array(strings(p["ai_keywords"]).prefix(5)) + (code ? ["code"] : []), trust: 0.7)
        }.prefix(100))
    }

    // MARK: Hacker News (Firebase)

    /// `topstories.json`: the first `limit` story ids.
    public static func hackerNewsIDs(_ data: Data, limit: Int = 30) -> [Int] {
        let ids = (json(data) as? [Any])?.prefix(2_000).compactMap { ($0 as? NSNumber).flatMap { Int(exactly: $0.doubleValue) } } ?? []
        return Array(ids.filter { $0 > 0 }.prefix(max(0, limit)))
    }

    /// `item/<id>.json` (one object) or several of them in an array. Stories and jobs with an outside link are news; one
    /// without a link (Ask HN, polls) is skipped; a link that is not https falls back to the discussion page. The score is the
    /// popularity.
    public static func hackerNews(_ data: Data) -> [RadarItem] {
        let root = json(data)
        let objects = (root as? [String: Any]).map { [$0] } ?? list(root)
        return Array(objects.lazy.compactMap { d -> RadarItem? in
            guard ["story", "job"].contains(str(d, "type")), d["dead"] as? Bool != true, d["deleted"] as? Bool != true,
                  let id = int(d, "id"), id > 0, let link = str(d, "url"), !link.isEmpty else { return nil }
            return RadarItem(kind: .news, title: str(d, "title") ?? "",
                             url: Plain.https(link) ?? "https://news.ycombinator.com/item?id=\(id)", source: "Hacker News",
                             published: When.epoch(num(d, "time")), popularity: num(d, "score"), trust: 0.5)
        }.prefix(100))
    }

    // MARK: news: RSS 2.0 and Atom

    /// A user-chosen feed (RSS 2.0, RSS 1.0 or Atom): title, link, date and a plain-text snippet of the description. `source`
    /// names the feed; empty, the item's own domain is used.
    public static func news(_ data: Data, source: String = "") -> [RadarItem] {
        entries(data, limit: 100).compactMap { e in
            let link = [e.fields["link"], e.fields["guid"], e.fields["id"]].compactMap { $0 }.first { Plain.https($0) != nil }
            let body = e.fields["description"] ?? e.fields["summary"] ?? e.fields["content:encoded"] ?? e.fields["content"] ?? ""
            let when = e.fields["pubDate"] ?? e.fields["published"] ?? e.fields["updated"] ?? e.fields["dc:date"]
            return RadarItem(kind: .news, title: e.fields["title"] ?? "", url: link ?? "", source: source, snippet: body,
                             published: When.parse(when), tags: Array(e.categories.prefix(4)), trust: 0.6)
        }
    }

    // MARK: internships

    /// SimplifyJobs `listings.json`: active and visible entries only (a missing flag counts as yes), each an internship
    /// posted `date_posted`. "Other" sponsorship means unknown. The title carries the company.
    public static func simplify(_ data: Data) -> [RadarItem] {
        Array(list(json(data)).lazy.compactMap { d -> RadarItem? in
            guard d["active"] as? Bool != false, d["is_visible"] as? Bool != false, let company = str(d, "company_name"),
                  let role = str(d, "title"), let url = str(d, "url") else { return nil }
            let places = strings(d["locations"])
            let sponsorship = str(d, "sponsorship").flatMap { $0 == "Other" ? nil : $0 }
            let degrees = strings(d["degrees"])
            return RadarItem(kind: .internship, title: company + " — " + role, url: url, source: "SimplifyJobs",
                             published: When.epoch(num(d, "date_posted")),
                             tags: [str(d, "category")].compactMap { $0 } + strings(d["terms"]), location: places,
                             remote: places.contains(where: isRemote) ? true : nil,
                             eligibility: degrees.isEmpty ? nil : "Degrees: " + degrees.joined(separator: ", "),
                             sponsorship: sponsorship, company: company, trust: 0.6)
        }.prefix(2_000))
    }

    /// `boards-api.greenhouse.io/v1/boards/{token}/jobs`. A board lists every job, so only early-career roles are kept (see
    /// `earlyCareer`). `company` is used when the job carries no `company_name`. The "Location Type" metadata, when set,
    /// says remote or on-site.
    public static func greenhouse(_ data: Data, company: String = "") -> [RadarItem] {
        guard let root = json(data) as? [String: Any] else { return [] }
        return Array(list(root["jobs"]).lazy.compactMap { j -> RadarItem? in
            guard let title = str(j, "title"), earlyCareer(title), let url = str(j, "absolute_url") else { return nil }
            let places = splitLocations((j["location"] as? [String: Any]).flatMap { str($0, "name") } ?? "")
            let type = list(j["metadata"]).first { str($0, "name") == "Location Type" }.flatMap { str($0, "value") }
            let name = str(j, "company_name") ?? company
            return RadarItem(kind: .internship, title: name.isEmpty ? title : name + " — " + title, url: url, source: "Greenhouse",
                             published: When.parse(str(j, "first_published") ?? str(j, "updated_at")),
                             deadline: When.parse(str(j, "application_deadline")), location: places,
                             remote: remoteFlag(type, places), company: name, trust: 0.9)
        }.prefix(300))
    }

    /// `api.lever.co/v0/postings/{site}?mode=json`. `categories.commitment` is free text ("Intern", "Full-time"); it and the
    /// title decide whether the role is early-career.
    public static func lever(_ data: Data, company: String = "") -> [RadarItem] {
        Array(list(json(data)).lazy.compactMap { j -> RadarItem? in
            let cat = j["categories"] as? [String: Any] ?? [:]
            let commitment = str(cat, "commitment") ?? ""
            guard let title = str(j, "text"), earlyCareer(title + " " + commitment),
                  let url = [str(j, "hostedUrl"), str(j, "applyUrl")].compactMap({ $0 }).first(where: { Plain.https($0) != nil })
            else { return nil }
            let places = strings(cat["allLocations"]).isEmpty ? [str(cat, "location")].compactMap { $0 } : strings(cat["allLocations"])
            return RadarItem(kind: .internship, title: company.isEmpty ? title : company + " — " + title, url: url, source: "Lever",
                             snippet: str(j, "descriptionPlain") ?? "", published: When.epoch(num(j, "createdAt")),
                             tags: [commitment, str(cat, "team") ?? ""], location: places,
                             remote: remoteFlag(str(j, "workplaceType"), places), company: company, trust: 0.9)
        }.prefix(300))
    }

    /// `api.ashbyhq.com/posting-api/job-board/{name}`: unlisted jobs (`isListed == false`) are dropped; early-career roles
    /// only (title or `employmentType` "Intern").
    public static func ashby(_ data: Data, company: String = "") -> [RadarItem] {
        guard let root = json(data) as? [String: Any] else { return [] }
        return Array(list(root["jobs"]).lazy.compactMap { j -> RadarItem? in
            guard j["isListed"] as? Bool != false, let title = str(j, "title"), earlyCareer(title + " " + (str(j, "employmentType") ?? "")),
                  let url = [str(j, "jobUrl"), str(j, "applyUrl")].compactMap({ $0 }).first(where: { Plain.https($0) != nil })
            else { return nil }
            let places = ([str(j, "location")] + list(j["secondaryLocations"]).map { str($0, "location") }).compactMap { $0 }
            return RadarItem(kind: .internship, title: company.isEmpty ? title : company + " — " + title, url: url, source: "Ashby",
                             snippet: str(j, "descriptionPlain") ?? str(j, "descriptionHtml") ?? "",
                             published: When.parse(str(j, "publishedAt")), tags: [str(j, "team") ?? "", str(j, "department") ?? ""],
                             location: places,
                             remote: (j["isRemote"] as? Bool) ?? remoteFlag(str(j, "workplaceType"), places), company: company, trust: 0.9)
        }.prefix(300))
    }

    // MARK: contests

    /// `ctftime.org/api/v1/events/`: the CTFtime page is the link (the organiser's own site is not trusted), the start is the
    /// deadline, `weight` the popularity, `restrictions` the eligibility, `onsite` decides remote.
    public static func ctftime(_ data: Data) -> [RadarItem] {
        Array(list(json(data)).lazy.compactMap { e -> RadarItem? in
            guard let id = int(e, "id"), id > 0, let title = str(e, "title"), let url = str(e, "ctftime_url") else { return nil }
            let onsite = e["onsite"] as? Bool
            let place = str(e, "location") ?? ""
            return RadarItem(id: "ctftime:\(id)", kind: .contest, title: title, url: url, source: "CTFtime",
                             snippet: str(e, "description") ?? "", deadline: When.parse(str(e, "start")), deadlineNote: "event start",
                             popularity: num(e, "weight"), tags: ["CTF", str(e, "format") ?? ""],
                             location: onsite == true ? (place.isEmpty ? [] : [place]) : ["online"], remote: onsite.map { !$0 },
                             eligibility: str(e, "restrictions"), trust: 0.8)
        }.prefix(100))
    }

    /// Codeforces `contest.list`: contests that have not started (`phase` BEFORE); the start is the deadline.
    public static func codeforces(_ data: Data) -> [RadarItem] {
        guard let root = json(data) as? [String: Any], str(root, "status") == "OK" else { return [] }
        return Array(list(root["result"]).lazy.compactMap { c -> RadarItem? in
            guard str(c, "phase") == "BEFORE", let id = int(c, "id"), id > 0, let name = str(c, "name") else { return nil }
            let kind = str(c, "type") ?? "CF"
            let length = num(c, "durationSeconds").map { ", " + span($0) } ?? ""
            return RadarItem(id: "codeforces:\(id)", kind: .contest, title: name, url: "https://codeforces.com/contests/\(id)",
                             source: "Codeforces", snippet: "\(kind) contest\(length)", deadline: When.epoch(num(c, "startTimeSeconds")),
                             deadlineNote: "event start", tags: ["Codeforces", "competitive programming"], location: ["online"],
                             remote: true, trust: 0.9)
        }.prefix(50))
    }

    // MARK: apply link check

    private static let atsHosts = ["greenhouse.io", "lever.co", "ashbyhq.com", "workable.com", "smartrecruiters.com",
                                   "myworkdayjobs.com", "icims.com", "jobvite.com"]
    private static let legalWords: Set<String> = ["inc", "llc", "ltd", "corp", "corporation", "co", "company", "group", "the",
                                                  "gmbh", "ag", "plc", "sa", "bv", "limited"]

    /// A warning when the apply link is neither the employer's own domain nor a known applicant-tracking host; nil when it is
    /// one of those. An ATS host does not prove the employer is real: anyone can open a board there, so this only catches a
    /// link that goes somewhere unrelated. ponytail: the own-domain test compares the company's words with the host's
    /// registrable label ("careers.google.com" / Google, "metacareers.com" / Meta); a parent company on another domain gets a
    /// warning, which is the safe side.
    public static func applyWarning(for url: String, company: String) -> String? {
        guard url.lowercased().hasPrefix("https://"), let host = URLComponents(string: url)?.host?.lowercased() else {
            return "The apply link is not a secure (https) link. Do not enter personal details there."
        }
        if atsHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return nil }
        if ownDomain(host, company: company) { return nil }
        let owner = Plain.text(company, max: 40)
        let who = owner.isEmpty ? "a known job board" : "\(owner)'s own site or a known job board"
        return "The apply link goes to \(host), which is not \(who). Check the employer before you enter any details."
    }

    private static func ownDomain(_ host: String, company: String) -> Bool {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return false }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "edu", "gov"]
        let at = labels.count >= 3 && labels[labels.count - 1].count == 2 && secondLevel.contains(labels[labels.count - 2])
            ? labels.count - 3 : labels.count - 2
        let brand = labels[at]
        let words = company.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !legalWords.contains($0) }
        guard !words.isEmpty else { return false }
        return (words + [words.joined()]).contains { w in
            brand == w || (w.count >= 3 && [w + "careers", w + "career", w + "jobs", "careers" + w, "jobs" + w].contains(brand))
        }
    }

    // MARK: shared helpers

    /// Titles of roles for students and new graduates; a company board lists every job, and the radar wants these.
    static func earlyCareer(_ text: String) -> Bool {
        text.range(of: #"\b(?:interns?|internships?|co-?ops?|students?|werkstudent|trainees?|apprentice(?:ship)?s?|new[ -]grad(?:uate)?s?|graduates?|early[ -]career)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isRemote(_ place: String) -> Bool { place.localizedCaseInsensitiveContains("remote") }

    /// Whether a job is remote, from the board's own workplace field ("Remote" / "On-site" / "OnSite" -> true / false, hybrid or
    /// anything else -> nil); only when the board gave none, from the words of its places.
    static func remoteFlag(_ workplace: String?, _ places: [String]) -> Bool? {
        if let workplace, !workplace.isEmpty {
            switch workplace.lowercased().replacingOccurrences(of: "-", with: "") {
            case "remote": return true
            case "onsite": return false
            default: return nil
            }
        }
        return places.contains(where: isRemote) ? true : nil
    }

    /// "San Francisco, CA | Seattle, WA" and "New York, NY; Boston, MA" -> one entry per place.
    static func splitLocations(_ text: String) -> [String] {
        text.prefix(2_000).split(whereSeparator: { $0 == ";" || $0 == "|" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func span(_ seconds: Double) -> String {
        let minutes = Int(min(max(seconds, 0), 1e7) / 60)
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    // JSON: tolerant lookups, so one odd entry loses only itself.
    private static func json(_ data: Data) -> Any? {
        data.count <= maxJSON && shallow(data) ? try? JSONSerialization.jsonObject(with: data) : nil
    }

    /// No more than 32 levels of [ and {. JSONSerialization recurses up to 512 levels deep, and on a worker thread (512 KB of
    /// stack, not the main thread's 8 MB) an unterminated `{"a":{"a":...` blows the stack: a feed could crash the app. Real
    /// feeds are 3 to 6 levels deep.
    static func shallow(_ data: Data, limit: Int = 32) -> Bool {
        data.withUnsafeBytes { bytes in
            var depth = 0, inString = false, escaped = false
            for b in bytes {
                if inString {
                    if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
                } else if b == 0x22 {
                    inString = true
                } else if b == 0x5B || b == 0x7B {
                    depth += 1
                    if depth > limit { return false }
                } else if b == 0x5D || b == 0x7D {
                    depth = max(0, depth - 1)
                }
            }
            return true
        }
    }

    private static func list(_ value: Any?) -> [[String: Any]] { (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
    private static func strings(_ value: Any?) -> [String] { (value as? [Any])?.compactMap { $0 as? String } ?? [] }
    private static func str(_ d: [String: Any], _ key: String) -> String? { d[key] as? String }

    private static func num(_ d: [String: Any], _ key: String) -> Double? {
        if let n = d[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue.isFinite ? n.doubleValue : nil }
        return (d[key] as? String).flatMap(Double.init)
    }

    private static func int(_ d: [String: Any], _ key: String) -> Int? { num(d, key).flatMap { Int(exactly: $0) } }

    // MARK: XML as a stream

    struct Entry {
        var fields: [String: String] = [:]
        var categories: [String] = []
    }

    /// The `<entry>` (Atom) or `<item>` (RSS) elements of a feed, at most `limit`. Each entry's direct children become
    /// `fields` by their qualified name ("title", "arxiv:announce_type"), first one wins; an Atom `<link>` counts when it is
    /// the alternate link. Junk, a truncated feed or a rejected document gives what was read before (or nothing).
    static func entries(_ data: Data, limit: Int) -> [Entry] {
        let body = Data(data.prefix(maxXML))
        // UTF-16/32 would hide a DOCTYPE from the search below.
        guard !body.isEmpty, !body.prefix(4_096).contains(0), !body.starts(with: [0xFF, 0xFE]), !body.starts(with: [0xFE, 0xFF]) else { return [] }
        for forbidden in ["<!DOCTYPE", "<!ENTITY"] where body.range(of: Data(forbidden.utf8)) != nil { return [] }
        let collector = EntryCollector(limit: limit)
        let parser = XMLParser(data: body)
        parser.delegate = collector
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return collector.entries
    }

    private final class EntryCollector: NSObject, XMLParserDelegate {
        private(set) var entries: [Entry] = []
        private var current: Entry?
        private var depth = 0  // 0 = the entry element itself, 1 = its children
        private var text = ""
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            guard current != nil else {
                if name == "entry" || name == "item" {
                    current = Entry()
                    depth = 0
                    text = ""
                }
                return
            }
            depth += 1
            guard depth == 1 else { return }
            text = ""
            if name == "link", let href = attributes["href"], ["", "alternate"].contains(attributes["rel"] ?? ""),
               current?.fields["link"] == nil {
                current?.fields["link"] = href
            }
            if name == "category", let term = attributes["term"] { current?.categories.append(term) }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { add(string) }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { add(String(decoding: CDATABlock, as: UTF8.self)) }

        private func add(_ s: String) {
            if current != nil, depth >= 1, text.utf8.count < 30_000 { text += s }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard current != nil else { return }
            if depth == 0 {
                entries.append(current!)
                current = nil
                if entries.count >= limit { parser.abortParsing() }
                return
            }
            if depth == 1 {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if name == "category" {
                    if !value.isEmpty { current?.categories.append(value) }
                } else if !value.isEmpty, current?.fields[name] == nil {
                    current?.fields[name] = value
                }
            }
            depth -= 1
        }
    }
}

/// Dates as feeds write them.
enum When {
    private static let iso = options([.withInternetDateTime])
    private static let isoFraction = options([.withInternetDateTime, .withFractionalSeconds])
    private static let day = options([.withFullDate])
    // Without the weekday: feeds get it wrong, and a wrong one would fail the whole date.
    private static let rfc822: [DateFormatter] = [
        "d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm zzz",
    ].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = $0
        return f
    }

    private static func options(_ o: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = o
        return f
    }

    /// ISO 8601 ("2026-10-19T04:00:34.864776+00:00", "2026-10-24") or RFC 822 ("Mon, 19 Oct 2026 14:20:00 -0400"); else nil.
    static func parse(_ text: String?) -> Date? {
        guard let s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.utf8.count <= 64 else { return nil }
        if let d = iso.date(from: s) ?? isoFraction.date(from: s) ?? day.date(from: s) { return d }
        let noWeekday = s.replacingOccurrences(of: #"^[A-Za-z]{3,9},\s*"#, with: "", options: .regularExpression)
        for f in rfc822 { if let d = f.date(from: noWeekday) { return d } }
        return nil
    }

    /// Epoch seconds, or milliseconds when the number is too big to be seconds (Lever writes milliseconds).
    static func epoch(_ value: Double?) -> Date? {
        guard let v = value, v.isFinite, v > 0 else { return nil }
        return Date(timeIntervalSince1970: v > 1e11 ? v / 1000 : v)
    }
}

/// Programmes with a calendar of their own, listed by hand with the official page. Dates change every year and are not
/// guessed here: each item says "check the official page". Re-check the list now and then (`verified`).
public enum Programmes {
    /// The day every page below was last confirmed to exist (an HTTP 200 on the official URL).
    public static let verified = When.parse("2026-10-20T00:00:00Z") ?? .distantPast

    public static let all: [RadarItem] = rows.compactMap { r in
        RadarItem(kind: r.hackathon ? .hackathon : .program, title: r.title, url: r.url, source: r.source,
                  snippet: r.about + " Last checked 2026-10-20.", deadlineNote: "check the official page", tags: r.tags,
                  location: [r.region], remote: r.remote, eligibility: r.eligibility, trust: 1)
    }

    private static let rows: [(title: String, url: String, source: String, about: String, region: String, remote: Bool,
                               eligibility: String, tags: [String], hackathon: Bool)] = [
        ("Google Summer of Code", "https://summerofcode.withgoogle.com", "Google",
         "Paid, mentored open-source projects over the summer for people new to open source. Applications open once a year, in spring.",
         "Worldwide (remote)", true, "Adults who are new to open source; the current rules are on the official page.",
         ["open source", "mentoring", "summer"], false),
        ("Outreachy internships", "https://www.outreachy.org", "Outreachy",
         "Paid, remote internships in open source and open science, in two rounds a year, for people who face under-representation or systemic bias in tech.",
         "Worldwide (remote)", true, "People who face under-representation or systemic bias in tech where they live; see the official page for the rules.",
         ["open source", "remote", "internship"], false),
        ("DAAD RISE Germany", "https://www.daad.de/rise/en/rise-germany/", "DAAD",
         "Summer research internships at German universities and research institutes for undergraduates, with a DAAD scholarship.",
         "Germany", false, "Undergraduates in science and engineering from selected countries; the list is on the official page.",
         ["research", "germany", "summer", "scholarship"], false),
        ("Mitacs Globalink Research Internship", "https://www.mitacs.ca/our-programs/globalink-research-internship-students/", "Mitacs",
         "Research internships at Canadian universities for undergraduates from partner countries.",
         "Canada", false, "Undergraduates from partner countries; the country list is on the official page.",
         ["research", "canada", "internship"], false),
        ("CERN Summer Student Programme", "https://careers.cern/summer", "CERN",
         "A summer programme at CERN for university students in physics, computing, engineering and related fields: lectures and work in a CERN team.",
         "Switzerland (Geneva)", false, "University students in the relevant fields; nationality and study-year rules apply, see the official page.",
         ["physics", "computing", "engineering", "summer", "research"], false),
        ("MLH Global Hack Week", "https://ghw.mlh.com/", "MLH",
         "Free, online hack weeks from Major League Hacking with workshops and mini-challenges, several times a year.",
         "Worldwide (online)", true, "Beginner-friendly and free to join; dates and rules are on the official page.",
         ["hackathon", "online", "beginner"], true),
        ("MLH Fellowship", "https://fellowship.mlh.com/", "MLH",
         "A remote, project-based software fellowship from Major League Hacking, run in cohorts, as an alternative to a classic internship.",
         "Worldwide (remote)", true, "Aspiring and early-career software engineers; the current rules are on the official page.",
         ["fellowship", "remote", "software", "internship"], false),
    ]
}
