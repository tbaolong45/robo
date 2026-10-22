// One thing the radar found: a paper, a headline, an announcement of a lab or company, a code repository, an internship, a programme, a
// contest or a hackathon. Pure data. The feed
// parsers (FeedParsers.swift) are the trust boundary: an item only exists if it has a title and an https URL, and every
// text field arrives as plain text (no tags, no control or bidi characters), capped in length. The text is meant to be
// shown as plain text, never as HTML or Markdown. No network and no clock in this file.
import Foundation

public struct RadarItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case paper, news, announcement, repo, internship, program, contest, hackathon }

    /// Things to read or look at, which have no deadline to apply by (everything else is an opportunity).
    static let reading: Set<Kind> = [.paper, .news, .announcement, .repo]

    /// Dedupe key: "arxiv:<id>", "doi:<doi>", a source's own stable id ("ctftime:3451"), else the normalised URL.
    public var id: String
    public var kind: Kind
    public var title: String
    /// https only.
    public var url: String
    /// A short name for where it came from ("arXiv", "Hacker News").
    public var source: String
    /// Plain text, at most 300 characters.
    public var snippet: String
    public var published: Date?
    /// When it matters: an application deadline, or the start of a contest.
    public var deadline: Date?
    /// For opportunities the card always says something about the deadline: "none stated" is explicit.
    public var deadlineNote: String?
    public var popularity: Double?
    public var tags: [String]
    public var location: [String]
    /// nil = the source did not say.
    public var remote: Bool?
    public var eligibility: String?
    public var sponsorship: String?
    /// The employer, for internships (the apply-link check needs it).
    public var company: String?
    /// How far to believe the source, 0...1.
    public var trust: Double

    /// The domain of `url` without "www.".
    public var host: String {
        let h = URLComponents(string: url)?.host?.lowercased() ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    public var isOpportunity: Bool { !Self.reading.contains(kind) }

    /// nil when there is no title or no https URL. Decoding (`Codable`) does not re-check: the cache is robo's own file.
    public init?(id: String? = nil, kind: Kind, title: String, url: String, source: String, snippet: String = "",
                 published: Date? = nil, deadline: Date? = nil, deadlineNote: String? = nil, popularity: Double? = nil,
                 tags: [String] = [], location: [String] = [], remote: Bool? = nil, eligibility: String? = nil,
                 sponsorship: String? = nil, company: String? = nil, trust: Double) {
        let title = Plain.text(title, max: 200)
        guard !title.isEmpty, let url = Plain.https(url) else { return nil }
        let own = id.map { Plain.text($0, max: 200) } ?? ""
        let deadline = Plain.sane(deadline)
        self.id = own.isEmpty ? Plain.key(url) : own
        self.kind = kind
        self.title = title
        self.url = url
        let name = Plain.text(source, max: 40)
        self.source = name.isEmpty ? (URLComponents(string: url)?.host ?? "") : name
        self.snippet = Plain.text(snippet, max: 300)
        self.published = Plain.sane(published)
        self.deadline = deadline
        let note = deadlineNote.map { Plain.text($0, max: 80) }.flatMap { $0.isEmpty ? nil : $0 }
        self.deadlineNote = note ?? (deadline == nil && !Self.reading.contains(kind) ? "none stated" : nil)
        self.popularity = popularity.flatMap { $0.isFinite ? max(0, $0) : nil }
        self.tags = Self.clean(tags, count: 8, max: 40)
        self.location = Self.clean(location, count: 6, max: 80)
        self.remote = remote
        self.eligibility = Self.optional(eligibility, max: 200)
        self.sponsorship = Self.optional(sponsorship, max: 80)
        self.company = Self.optional(company, max: 80)
        self.trust = trust.isFinite ? min(max(trust, 0), 1) : 0
    }

    private static func clean(_ list: [String], count: Int, max: Int) -> [String] {
        var seen = Set<String>()
        return list.prefix(count * 4).map { Plain.text($0, max: max) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(count).map { $0 }
    }

    private static func optional(_ text: String?, max: Int) -> String? {
        let t = text.map { Plain.text($0, max: max) } ?? ""
        return t.isEmpty ? nil : t
    }
}

/// Plain text and URLs from anything a feed can throw at the parsers.
enum Plain {
    /// `raw` as one line of plain text of at most `max` characters: tags (and the content of script and style) removed, HTML
    /// entities decoded, control, format (bidi, zero-width) and private-use characters dropped, whitespace collapsed, a cut
    /// ends in "…". Only the first 20 000 characters are looked at, so a giant field costs the same as a big one.
    static func text(_ raw: String, max: Int) -> String {
        let s = strip(unescape(strip(String(raw.prefix(20_000)))))
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u.properties.isWhitespace {
                out.append(" ")
                continue
            }
            switch u.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned: continue
            default: out.append(u)
            }
        }
        let t = String(out).split(separator: " ").joined(separator: " ")
        guard t.count > max else { return t }
        return String(t.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func strip(_ s: String) -> String {
        guard s.contains("<") else { return s }
        // script/style with their content and comments go whole (an unterminated one runs to the end); inline tags vanish
        // ("H<sub>2</sub>O", "<i>word</i>." stay one word); any other tag becomes a space. A "<" that does not start a tag
        // ("a < b") stays.
        return s.replacingOccurrences(of: #"(?is)<(script|style)\b.*?(?:</\1\s*>|\z)|<!--.*?(?:-->|\z)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</?(?:a|b|i|u|s|q|em|tt|sub|sup|span|code|font|mark|small|strong|abbr|cite|del|ins)\b[^<>]*>"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: #"</?[A-Za-z][^<>]*>"#, with: " ", options: .regularExpression)
    }

    private static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = "", i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(10).firstIndex(of: ";"), let r = entity(s[s.index(after: i)..<semi]) {
                out += r
                i = s.index(after: semi)
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func entity(_ name: Substring) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "ndash": return "–"
        case "mdash": return "—"
        case "hellip": return "…"
        case "lsquo", "rsquo": return "'"
        case "ldquo", "rdquo": return "\""
        default:
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let code = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }

    /// `raw` as an https URL with a dotted host, no credentials, no spaces or control characters, at most 2000 bytes; else nil
    /// (javascript:, http:, data:, ftp:, "//host/path" and "/relative" all end up nil).
    static func https(_ raw: String) -> String? {
        guard raw.utf8.count <= 4_000 else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.utf8.count <= 2_000, !t.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }),
              var c = URLComponents(string: t), c.scheme?.lowercased() == "https", let host = c.host, host.contains("."),
              c.user == nil, c.password == nil else { return nil }
        c.scheme = "https"
        return c.string
    }

    /// The dedupe form of a URL: https, lower-case host without "www.", no fragment, no default port, no trailing slash,
    /// tracking parameters dropped and the rest sorted.
    static func normalised(_ url: String) -> String {
        guard let c = URLComponents(string: url), let host = c.host?.lowercased() else { return url.lowercased() }
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        let items = (c.queryItems ?? []).filter { !tracking($0.name) }.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        var out = "https://" + (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        if let port = c.port, port != 443 { out += ":\(port)" }
        out += path
        if !items.isEmpty { out += "?" + items.map { $0.name + ($0.value.map { "=" + $0 } ?? "") }.joined(separator: "&") }
        return out
    }

    private static func tracking(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("utm_") || ["fbclid", "gclid", "mc_cid", "mc_eid", "ref", "ref_src", "igshid", "gh_src"].contains(n)
    }

    /// The id an item gets from its URL: "arxiv:<id>" for an arXiv abs/pdf link (so a Hacker News post of a paper and the
    /// paper itself are one item), "doi:<doi>" for a doi.org link, else the normalised URL.
    static func key(_ url: String) -> String {
        if let c = URLComponents(string: url), let host = c.host?.lowercased() {
            if host == "arxiv.org" || host.hasSuffix(".arxiv.org"), let id = arxivID(inPath: c.path) { return "arxiv:" + id }
            if host == "doi.org" || host == "dx.doi.org", c.path.hasPrefix("/10.") { return "doi:" + c.path.dropFirst().lowercased() }
        }
        return normalised(url)
    }

    /// "/abs/2410.01234v2", "/pdf/2410.01234.pdf" or "/html/hep-th/9901001" -> the id without version; nil when not an arXiv id.
    static func arxivID(inPath path: String) -> String? {
        for prefix in ["/abs/", "/pdf/", "/html/"] where path.hasPrefix(prefix) { return arxivID(from: String(path.dropFirst(prefix.count))) }
        return nil
    }

    /// "2410.01234v2", "oai:arXiv.org:2410.01234v1" (the part after the last colon), "2410.01234.pdf" -> "2410.01234". Old-style
    /// "hep-th/9901001" too. nil when the rest is not an arXiv id.
    static func arxivID(from raw: String) -> String? {
        var id = String(raw.split(separator: ":").last ?? "")
        if id.hasSuffix(".pdf") { id.removeLast(4) }
        id = id.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
        return id.range(of: #"^(?:\d{4}\.\d{4,5}|[a-z]+(?:-[a-z]+)*(?:\.[A-Za-z]{2})?/\d{7})$"#, options: .regularExpression) == nil ? nil : id
    }

    /// Dates before 1990 or after 2100 are a parse accident, not a date.
    static func sane(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970 > 631_152_000, date.timeIntervalSince1970 < 4_102_444_800 else { return nil }
        return date
    }
}
