// What the radar knows about you: the vault note `Radar/Profile.md`, plain Obsidian Markdown with one `- key: value` line per
// setting. Everything is optional: a blank value is "unknown", and the radar only filters on values you actually gave.
// Pure: parsing a string, matching an item against it. The note is read by the app, never sent anywhere.
import Foundation

public struct Profile: Equatable, Sendable {
    /// One thing you want to learn about: a word or phrase and how much it counts (`vision*2`; default 1).
    public struct Term: Equatable, Sendable {
        public var text: String
        public var weight: Double
        public init(text: String, weight: Double = 1) { (self.text, self.weight) = (text, weight) }
    }

    /// A company job board to watch: `greenhouse:<token>`, `lever:<site>` or `ashby:<name>`.
    public struct Company: Equatable, Sendable {
        public enum Board: String, Sendable { case greenhouse, lever, ashby }
        public var board: Board
        public var token: String
        public init(board: Board, token: String) { (self.board, self.token) = (board, token) }
    }

    public enum Eligibility: Equatable, Sendable {
        case fits, unclear, excluded

        /// The line the card shows.
        public var note: String {
            switch self {
            case .fits: "fits what you told Robo"
            case .unclear: "eligibility unclear, check"
            case .excluded: "outside what you told Robo"
            }
        }
    }

    public var interests: [Term] = []
    public var goals = ""
    public var level = ""
    /// "YYYY-MM", or nil.
    public var graduation: String?
    public var country: String?
    public var citizenship: String?
    public var needsSponsorship: Bool?
    /// true = wants remote only, false = wants on-site only, nil = either.
    public var remote: Bool?
    public var arxivCategories = ["cs.AI", "cs.LG"]
    public var companies: [Company] = []
    public var feeds: [String] = []
    public var exclude: [String] = []
    /// Words from items you marked "Not for me". Kept by the app in a local file, not in the note.
    public var dislikes: [String] = []

    public init() {}

    // MARK: reading the note

    /// The profile in `markdown`. Never fails: unknown lines, comments (`%% %%`, `<!-- -->`), quotes and code blocks are
    /// ignored, a value that does not make sense counts as blank, and every list has a cap.
    public static func parse(markdown: String) -> Profile {
        var p = Profile()
        let text = String(markdown.prefix(100_000))
            .replacingOccurrences(of: #"(?s)%%.*?(?:%%|\z)|<!--.*?(?:-->|\z)|```.*?(?:```|\z)"#, with: "\n", options: .regularExpression)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            guard let bullet = line.first, "-*+".contains(bullet), line.dropFirst().first == " ", let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.index(after: line.startIndex)..<colon].filter(\.isLetter).lowercased()
            let value = line[line.index(after: colon)...].drop { $0 == "*" || $0 == " " || $0 == "\t" }
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "interests": p.interests = terms(value)
            case "goals": p.goals = Plain.text(value, max: 200)
            case "level": p.level = Plain.text(value, max: 60)
            case "graduation": p.graduation = value.range(of: #"^\d{4}-(?:0[1-9]|1[0-2])$"#, options: .regularExpression) == nil ? nil : value
            case "country": p.country = optional(value)
            case "citizenship": p.citizenship = optional(value)
            case "needssponsorship": p.needsSponsorship = yesNo(value)
            case "remote": p.remote = yesNo(value)
            case "arxivcategories": p.arxivCategories = categories(value)
            case "companies": p.companies = companies(value)
            case "feeds": p.feeds = urls(value)
            case "exclude": p.exclude = words(value)
            default: break
            }
        }
        return p
    }

    private static func optional(_ value: String) -> String? {
        let t = Plain.text(value, max: 60)
        return t.isEmpty ? nil : t
    }

    /// yes / y / true -> true, no / n / false -> false, anything else (blank, "any", "maybe") -> nil.
    private static func yesNo(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "yes", "y", "true": true
        case "no", "n", "false": false
        default: nil
        }
    }

    private static func terms(_ value: String) -> [Term] {
        var out: [Term] = []
        for part in value.split(separator: ",").prefix(60) {
            var text = String(part), weight = 1.0
            if let star = text.lastIndex(of: "*"), let w = Double(text[text.index(after: star)...].trimmingCharacters(in: .whitespaces)),
               w.isFinite, w > 0 {
                weight = min(max(w, 0.1), 5)
                text = String(text[..<star])
            }
            text = Plain.text(text.filter { !"*_[]`".contains($0) }, max: 60).lowercased()
            guard !Rank.tokens(text).isEmpty else { continue }
            if let i = out.firstIndex(where: { $0.text == text }) {
                out[i].weight = max(out[i].weight, weight)
            } else {
                out.append(Term(text: text, weight: weight))
            }
        }
        return Array(out.prefix(30))
    }

    private static func categories(_ value: String) -> [String] {
        let valid = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^[a-z][a-z-]*(?:\.[A-Za-z-]+)?$"#, options: .regularExpression) != nil }
        var seen = Set<String>()
        let unique = valid.filter { seen.insert($0).inserted }
        return unique.isEmpty ? Profile().arxivCategories : Array(unique.prefix(8))
    }

    private static func companies(_ value: String) -> [Company] {
        var out: [Company] = []
        for part in value.split(separator: ",").prefix(80) {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let board = Company.Board(rawValue: pair[0].lowercased()),
                  pair[1].range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else { continue }
            let c = Company(board: board, token: pair[1])
            if !out.contains(c) { out.append(c) }
        }
        return Array(out.prefix(40))
    }

    /// Every https URL in the value, whatever surrounds it (`<url>`, `[name](url)`, commas, spaces).
    private static func urls(_ value: String) -> [String] {
        var out: [String] = []
        var rest = value[...]
        while let r = rest.range(of: #"https://[^\s,<>()\[\]]+"#, options: .regularExpression) {
            if let url = Plain.https(String(rest[r])), !out.contains(url) { out.append(url) }
            rest = rest[r.upperBound...]
        }
        return Array(out.prefix(20))
    }

    private static func words(_ value: String) -> [String] {
        var out: [String] = []
        for part in value.split(separator: ",").prefix(100) {
            let w = Plain.text(String(part), max: 40).lowercased()
            if !w.isEmpty, !out.contains(w) { out.append(w) }
        }
        return Array(out.prefix(50))
    }

    // MARK: the note to start from

    /// The note Robo creates on first run: every setting with a plain-English explanation in a quote above it (Obsidian shows
    /// these as callout-style blocks; the parser skips them).
    public static func template() -> String {
        """
        # Robo radar profile

        > Robo reads this note to choose the papers, news, internships and events it shows you. Each setting is one line that
        > starts with "- name:". Change the words after the colon. Leave a line empty if you would rather not say: Robo then
        > treats it as unknown and never filters on it. This note stays on your Mac.

        ## What you want to learn about

        > **interests**: topics you care about, separated by commas. Put *2 after a topic to make it count double.
        > Example: computer vision*2, robotics, medical imaging
        - interests:

        > **goals**: what you are working toward, in a few words. Example: a research internship in robotics.
        - goals:

        > **level**: where you are in your studies. Example: second-year bachelor, master's, PhD.
        - level:

        > **graduation**: when you finish, as year-month. Example: 2028-06
        - graduation:

        ## Where you can work or study

        > **country**: where you live or want to work. Postings in other countries are hidden only when this is filled in.
        - country:

        > **citizenship**: optional. Some postings are for citizens only.
        - citizenship:

        > **needsSponsorship**: yes if an employer would need to sponsor your visa, no if not, empty if unsure.
        - needsSponsorship:

        > **remote**: yes to see only remote roles, no to see only on-site roles, empty or "any" for both.
        - remote:

        ## Where Robo looks

        > **arxivCategories**: arXiv subject areas for new papers, separated by commas. Example: cs.CV, cs.RO, stat.ML
        - arxivCategories: cs.AI, cs.LG

        > **companies**: company job boards to watch for internships, separated by commas. Write greenhouse:name, lever:name
        > or ashby:name, where "name" is the last part of the company's job board address.
        - companies:

        > **feeds**: extra news feeds (RSS or Atom web addresses starting with https), separated by commas or spaces.
        - feeds:

        > **exclude**: words you never want to see, separated by commas. Items that contain one are left out.
        - exclude:
        """
    }

    // MARK: who it fits

    /// Does `item` fit what you said about yourself? Papers and news always do. For an opportunity only known values count:
    /// the posting's places against your country (internships only: a programme abroad is meant for people from abroad), its
    /// sponsorship statement against your need and citizenship, and remote against your preference. A known conflict is
    /// `.excluded`, everything known and matching is `.fits`, anything unknown is `.unclear` ("eligibility unclear, check").
    public func eligibility(for item: RadarItem) -> Eligibility {
        guard item.isOpportunity else { return .fits }
        if let want = remote, let has = item.remote, want != has { return .excluded }
        var checks: [Check] = [place(item)]
        if let s = sponsor(item) { checks.append(s) }
        if checks.contains(.no) { return .excluded }
        return checks.allSatisfy { $0 == .ok } ? .fits : .unclear
    }

    private enum Check { case ok, no, unknown }

    private func place(_ item: RadarItem) -> Check {
        guard !item.location.isEmpty else { return .unknown }
        let mine = Geo.countries(in: country ?? "")
        var allForeign = true
        for entry in item.location {
            let named = Geo.countries(in: entry)
            if named.isEmpty {
                if Geo.isGeneric(entry) { return .ok }
                allForeign = false
            } else if !named.isDisjoint(with: mine) {
                return .ok
            }
        }
        return allForeign && !mine.isEmpty && item.kind == .internship ? .no : .unknown
    }

    /// nil when sponsorship does not matter for this item.
    private func sponsor(_ item: RadarItem) -> Check? {
        let s = (item.sponsorship ?? "").lowercased().replacingOccurrences(of: ".", with: "")
        let citizens = s.contains("citizenship is required") || s.contains("citizens only") || s.contains("must be a us citizen")
        let closed = s.contains("does not offer") || s.contains("no sponsorship") || s.contains("not sponsor") || s.contains("cannot sponsor")
        let open = !closed && (s.contains("offers sponsorship") || s.contains("will sponsor") || s.contains("sponsorship available"))
        if needsSponsorship == true {
            if citizens || closed { return .no }
            return open ? .ok : .unknown
        }
        if citizens {
            let required = Geo.countries(in: s), mine = Geo.countries(in: citizenship ?? "")
            if required.isEmpty || mine.isEmpty { return .unknown }
            return required.isDisjoint(with: mine) ? .no : .ok
        }
        return needsSponsorship == nil && closed ? .unknown : nil
    }
}

/// Which countries a place name mentions: "Berlin, Germany", "Remote in USA", "Austin, TX" (a US state code) and so on.
private enum Geo {
    private static let table: [(name: String, words: [String])] = [
        ("united states", ["united states", "united states of america", "usa", "us", "america"]),
        ("united kingdom", ["united kingdom", "uk", "england", "scotland", "wales", "northern ireland", "britain", "great britain"]),
        ("canada", ["canada"]), ("germany", ["germany", "deutschland"]), ("france", ["france"]), ("netherlands", ["netherlands", "holland"]),
        ("switzerland", ["switzerland"]), ("ireland", ["ireland"]), ("vietnam", ["vietnam", "viet nam", "việt nam"]),
        ("india", ["india"]), ("china", ["china"]), ("japan", ["japan"]), ("south korea", ["south korea", "korea"]),
        ("singapore", ["singapore"]), ("australia", ["australia"]), ("new zealand", ["new zealand"]), ("spain", ["spain"]),
        ("italy", ["italy"]), ("sweden", ["sweden"]), ("norway", ["norway"]), ("denmark", ["denmark"]), ("finland", ["finland"]),
        ("poland", ["poland"]), ("austria", ["austria"]), ("belgium", ["belgium"]), ("portugal", ["portugal"]), ("israel", ["israel"]),
        ("brazil", ["brazil"]), ("mexico", ["mexico"]), ("uae", ["united arab emirates", "uae", "dubai"]), ("taiwan", ["taiwan"]),
        ("hong kong", ["hong kong"]), ("indonesia", ["indonesia"]), ("thailand", ["thailand"]), ("philippines", ["philippines"]),
        ("malaysia", ["malaysia"]), ("turkey", ["turkey", "türkiye"]), ("south africa", ["south africa"]), ("nigeria", ["nigeria"]),
    ]
    // "DE" is left out on purpose: in a posting it is Germany more often than Delaware.
    private static let usStates = Set("AL AK AZ AR CA CO CT FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY DC".split(separator: " ").map(String.init))
    private static let provinces = Set("ON BC QC AB MB SK NS NB NL PE".split(separator: " ").map(String.init))
    private static let generic = ["worldwide", "anywhere", "global", "online", "remote", "everywhere"]

    static func countries(in place: String) -> Set<String> {
        let t = place.precomposedStringWithCanonicalMapping
        let flat = " " + t.lowercased().replacingOccurrences(of: ".", with: "").split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != " " })
            .joined(separator: " ") + " "
        var found = Set(table.filter { $0.words.contains { flat.contains(" \($0) ") } }.map(\.name))
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        if let r = trimmed.range(of: #",\s*[A-Z]{2}(?:\s+\d{5}(?:-\d{4})?)?$"#, options: .regularExpression) {
            let code = String(trimmed[r].filter(\.isLetter))
            if usStates.contains(code) { found.insert("united states") } else if provinces.contains(code) { found.insert("canada") }
        }
        return found
    }

    /// "Remote", "Worldwide", "Online": a place that names no country and does not limit where you are.
    static func isGeneric(_ place: String) -> Bool {
        let lower = place.lowercased()
        return generic.contains { lower.contains($0) }
    }
}
