// The radar profile note (pure): reading `- key: value` lines out of Obsidian Markdown, the template, and who an opportunity
// fits. Only values the person gave are ever filtered on.
import Foundation
import Testing
@testable import RoboCore

private let filled = """
# Robo radar profile

> A quote that mentions the format: - interests: this must not be read, and neither must - country: Mars

%% a comment block with example lines
- country: Mars
- needsSponsorship: yes
%%

- interests: Computer Vision*2, robotics, [[medical imaging]]*1.5, **nlp**
- goals: a research internship in robotics: learn a lot
- level: second-year bachelor
- graduation: 2028-06
- country: Vietnam
- citizenship: Vietnam
- needsSponsorship: yes
- remote: any
- arxivCategories: cs.CV, cs.RO
- companies: greenhouse:anthropic, lever:palantir
- feeds: https://example.com/feed.xml
- exclude: Crypto, stock market

```
- interests: hacked by a code block
- level: Mars
```

<!-- - level: phd -->
- favourite colour: blue
Random text and | table | rows |
-notabullet: x
- **exclude:** NFT
"""

private func parse(_ lines: String...) -> Profile { Profile.parse(markdown: lines.joined(separator: "\n")) }

@Suite struct ProfileParseTests {
    @Test func aFilledNoteIsReadKeyByKey() {
        let p = Profile.parse(markdown: filled)
        #expect(p.interests == [.init(text: "computer vision", weight: 2), .init(text: "robotics", weight: 1),
                                .init(text: "medical imaging", weight: 1.5), .init(text: "nlp", weight: 1)])
        #expect(p.goals == "a research internship in robotics: learn a lot" && p.level == "second-year bachelor" && p.graduation == "2028-06")
        #expect(p.country == "Vietnam" && p.citizenship == "Vietnam" && p.needsSponsorship == true && p.remote == nil)
        #expect(p.arxivCategories == ["cs.CV", "cs.RO"])
        #expect(p.companies == [.init(board: .greenhouse, token: "anthropic"), .init(board: .lever, token: "palantir")])
        #expect(p.feeds == ["https://example.com/feed.xml"])
        #expect(p.exclude == ["nft"])  // the last exclude line wins
        #expect(p.dislikes.isEmpty)
    }

    @Test func quotesCommentsCodeBlocksAndUnknownLinesAreIgnored() {
        let p = Profile.parse(markdown: filled)
        #expect(p.country == "Vietnam" && p.level == "second-year bachelor")  // not Mars, not phd
        #expect(!p.interests.contains { $0.text.contains("hacked") })
        #expect(parse("- unknown: x", "random", "# heading", "| a | b |", "-country: Vietnam").country == nil)
        #expect(parse("%% never closed", "- country: Vietnam").country == nil)  // an open comment swallows the rest
    }

    @Test func theTemplateReadsBackAsTheDefaultProfile() {
        #expect(Profile.parse(markdown: Profile.template()) == Profile())
        #expect(Profile().arxivCategories == ["cs.AI", "cs.LG"] && Profile().interests.isEmpty && Profile().country == nil)
    }

    @Test func theTemplateExplainsEveryKeyInAQuote() {
        let template = Profile.template()
        for key in ["interests", "goals", "level", "graduation", "country", "citizenship", "needsSponsorship", "remote", "arxivCategories",
                    "companies", "feeds", "github", "exclude"] {
            #expect(template.contains("\n- \(key):"), "no line for \(key)")
            let lines = template.components(separatedBy: "\n")
            let at = lines.firstIndex { $0.hasPrefix("- \(key):") }!
            let above = lines[..<at].reversed().prefix { $0.hasPrefix(">") }
            #expect(above.contains { $0.contains("**\(key)**") }, "no explanation above \(key)")
        }
        #expect(template.contains("- arxivCategories: cs.AI, cs.LG") && template.hasPrefix("# Robo radar profile"))
    }

    @Test func blankValuesAreUnknown() {
        let p = parse("- interests:", "- goals:", "- level:", "- graduation:", "- country:", "- citizenship:", "- needsSponsorship:", "- remote:",
                      "- arxivCategories:", "- companies:", "- feeds:", "- exclude:")
        #expect(p == Profile())
    }

    @Test(arguments: [("yes", true), ("Yes", true), ("y", true), ("TRUE", true), ("no", false), ("NO", false), ("n", false), ("false", false)])
    func yesAndNoAnswers(_ text: String, _ expected: Bool) {
        #expect(parse("- needsSponsorship: \(text)", "- remote: \(text)").needsSponsorship == expected)
        #expect(parse("- remote: \(text)").remote == expected)
    }

    @Test(arguments: ["", "any", "maybe", "perhaps", "1", "yes please", "nope"])
    func anythingElseIsUnknown(_ text: String) {
        let p = parse("- needsSponsorship: \(text)", "- remote: \(text)")
        #expect(p.needsSponsorship == nil && p.remote == nil)
    }

    @Test(arguments: [("2028-06", "2028-06"), ("1999-12", "1999-12"), ("2028-13", nil), ("2028-6", nil), ("June 2028", nil), ("2028-06-01", nil), ("2028", nil),
                      ("", nil), ("soon", nil), ("0000-00", nil)] as [(String, String?)])
    func graduationIsYearAndMonth(_ text: String, _ expected: String?) {
        #expect(parse("- graduation: \(text)").graduation == expected)
    }

    @Test func interestsHaveWeightsClampedAndDuplicatesMerged() {
        let p = parse("- interests: zoom*99, slow*0.01, vision * 2, ROBOTICS*3, robotics, [[graphs]], `code`, !!!, a, ,   ")
        #expect(p.interests == [.init(text: "zoom", weight: 5), .init(text: "slow", weight: 0.1), .init(text: "vision", weight: 2),
                                .init(text: "robotics", weight: 3), .init(text: "graphs", weight: 1), .init(text: "code", weight: 1)])
    }

    @Test func interestsAreCappedInCountAndLength() {
        let p = parse("- interests: " + (0..<100_000).map { "term\($0)" }.joined(separator: ", "))
        #expect(p.interests.count == 30)
        let long = parse("- interests: " + String(repeating: "word ", count: 500))
        #expect(long.interests.count == 1 && long.interests[0].text.count <= 60)
    }

    @Test func arxivCategoriesAreValidatedAndDefaultWhenNoneIsValid() {
        #expect(parse("- arxivCategories: cs.CV, cs.RO, stat.ML, q-bio.NC, hep-th, bad cat, CS.AI, ; drop table, cs.CV").arxivCategories ==
                ["cs.CV", "cs.RO", "stat.ML", "q-bio.NC", "hep-th"])
        #expect(parse("- arxivCategories: nonsense words, ../x, 1.2").arxivCategories == ["cs.AI", "cs.LG"])
        #expect(parse("- arxivCategories: cs.AA, cs.BB, cs.CC, cs.DD, cs.EE, cs.FF, cs.GG, cs.HH, cs.II, cs.JJ").arxivCategories.count == 8)
    }

    @Test func companiesNeedAKnownBoardAndASafeToken() {
        let p = parse("- companies: greenhouse:anthropic, Lever:palantir, ashby:openai, workday:acme, greenhouse:bad token, greenhouse:../etc, "
                      + "lever:, :x, greenhouse:a:b, greenhouse:anthropic, ashby:Open-AI.v2, ashby:bad/slash, ashby:under_score")
        #expect(p.companies == [.init(board: .greenhouse, token: "anthropic"), .init(board: .lever, token: "palantir"),
                                .init(board: .ashby, token: "openai"), .init(board: .ashby, token: "Open-AI.v2"),
                                .init(board: .ashby, token: "under_score")])
        let long = parse("- companies: greenhouse:" + String(repeating: "a", count: 65))
        #expect(long.companies.isEmpty)
        let many = parse("- companies: " + (0..<100).map { "lever:site\($0)" }.joined(separator: ", "))
        #expect(many.companies.count == 40)
    }

    @Test func feedsMustBeHttpsWhateverTheMarkupAroundThem() {
        let p = parse("- feeds: https://a.example/feed.xml, http://insecure.example/x, <https://b.example/rss>, [Blog](https://c.example/atom.xml) "
                      + "javascript:alert(1) https://a.example/feed.xml ftp://d.example/f https://user:pw@e.example/x")
        #expect(p.feeds == ["https://a.example/feed.xml", "https://b.example/rss", "https://c.example/atom.xml"])
        #expect(parse("- feeds: " + (0..<50).map { "https://f\($0).example/x" }.joined(separator: " ")).feeds.count == 20)
    }

    @Test func githubSearchesTheStrongestInterestsUnlessTheNoteSaysOtherwise() {
        let p = parse("- interests: robotics, computer vision*3, nlp*3, medical imaging*2, ai safety")
        #expect(p.githubQueries == ["computer vision", "nlp", "medical imaging"])  // the heaviest three; the note's order breaks the tie
        #expect(parse("- interests: a b\n- github: rust, wasm runtime").githubQueries == ["rust", "wasm runtime"])  // the github line wins
        #expect(parse("- interests: robotics\n- github: alpha, beta, gamma, delta, epsilon").githubQueries == ["alpha", "beta", "gamma"])  // and is capped (the search allows 10 a minute)
        for off in ["none", "None", "off", "no"] { #expect(parse("- interests: robotics\n- github: \(off)").githubQueries.isEmpty, "\(off)") }
        #expect(parse("- interests:\n").githubQueries.isEmpty)  // nothing to look up
        #expect(parse("- interests: robotics\n- github:\n").githubQueries == ["robotics"])  // an empty line is the default
        #expect(Profile().githubQueries.isEmpty)
    }

    @Test func aWordOfTheNoteCannotAddASearchQualifier() {
        // the words are the only part of the profile that is in a URL: letters, digits, spaces and hyphens, nothing that GitHub reads as a qualifier
        let p = parse("- interests: user:octocat stars:>9999, repo:a/b, in:readme fork:true, -language:go, self-driving")
        #expect(p.githubQueries == ["useroctocat stars9999", "repoab", "inreadme forktrue"])
        #expect(parse("- github: ***, [], user:").githubQueries == ["user"])  // what is left of an empty word is dropped
        #expect(parse("- interests: self-driving cars").githubQueries == ["self-driving cars"])
    }

    @Test func excludedWordsAreLowerCasedTrimmedAndUnique() {
        #expect(parse("- exclude:  Crypto , NFT,, stock Market ,crypto").exclude == ["crypto", "nft", "stock market"])
    }

    @Test func bulletsKeysAndLineEndingsAreTolerated() {
        let p = Profile.parse(markdown: "\u{FEFF}* country: Vietnam\r\n+ Level : phd\r\n   - **Needs Sponsorship:** yes\r\n\t- remote:no\r\n- arxiv_categories: cs.CV\r\n")
        #expect(p.country == "Vietnam" && p.level == "phd" && p.needsSponsorship == true && p.remote == false && p.arxivCategories == ["cs.CV"])
    }

    @Test func textValuesAreCleanedAndCapped() {
        let p = parse("- goals: do\u{0007} this\u{202E} <b>now</b>", "- country: " + String(repeating: "x", count: 500))
        #expect(p.goals == "do this now" && p.country?.count == 60)
    }

    @Test func aHugeNoteIsReadQuicklyAndOnlyInPart() {
        let huge = String(repeating: "- junk: line\n", count: 200_000) + "- country: Vietnam\n"
        #expect(Profile.parse(markdown: huge).country == nil)  // past the 100 000 characters that are read
        #expect(Profile.parse(markdown: "").country == nil && Profile.parse(markdown: "\u{0}\u{1}\u{2}") == Profile())
    }
}

// MARK: who it fits

private func job(_ places: [String], sponsorship: String? = nil, remote: Bool? = nil, kind: RadarItem.Kind = .internship) -> RadarItem {
    RadarItem(kind: kind, title: "Intern", url: "https://example.org/j", source: "t", location: places, remote: remote, sponsorship: sponsorship, trust: 0.6)!
}

private func me(_ country: String? = nil, citizen: String? = nil, sponsor: Bool? = nil, remote: Bool? = nil) -> Profile {
    var p = Profile()
    (p.country, p.citizenship, p.needsSponsorship, p.remote) = (country, citizen, sponsor, remote)
    return p
}

@Suite struct EligibilityTests {
    @Test func papersAndNewsAlwaysFit() {
        let paper = RadarItem(kind: .paper, title: "P", url: "https://arxiv.org/abs/2610.00001", source: "arXiv", trust: 1)!
        #expect(me("Vietnam", sponsor: true, remote: true).eligibility(for: paper) == .fits && Profile().eligibility(for: paper) == .fits)
    }

    @Test func nothingKnownMeansUnclear() {
        #expect(Profile().eligibility(for: job(["New York, NY"])) == .unclear)
        #expect(Profile().eligibility(for: job([])) == .unclear)
        #expect(me("Atlantis").eligibility(for: job(["New York, NY"])) == .unclear)  // a country Robo cannot place
    }

    @Test(arguments: [
        ("United States", ["New York, NY"], Profile.Eligibility.fits), ("United States", ["Austin, TX, USA"], .fits), ("USA", ["Austin, TX 78701"], .fits),
        ("United States", ["Remote in USA"], .fits), ("United States", ["Toronto, ON"], .excluded), ("United States", ["Berlin, Germany"], .excluded),
        ("Vietnam", ["New York, NY"], .excluded), ("Vietnam", ["Hanoi, Vietnam"], .fits), ("Vietnam", ["Hà Nội, Việt Nam"], .fits),
        ("Vietnam", ["Remote"], .fits), ("Vietnam", ["Worldwide"], .fits), ("Vietnam", ["Anywhere"], .fits), ("Vietnam", ["Remote in USA"], .excluded),
        ("Vietnam", ["Remote - Vietnam"], .fits), ("Vietnam", ["Berlin"], .unclear), ("Vietnam", ["Berlin", "New York, NY"], .unclear),
        ("Vietnam", ["Berlin, Germany", "London, UK"], .excluded), ("Vietnam", ["Berlin, Germany", "Hanoi, Vietnam"], .fits),
        ("Vietnam", ["New York, NY", "Remote"], .fits), ("Vietnam", ["Toronto, ON"], .excluded), ("UK", ["London, England"], .fits),
        ("United Kingdom", ["Edinburgh, Scotland"], .fits), ("Germany", ["Munich, Germany"], .fits), ("Canada", ["Vancouver, BC"], .fits),
    ])
    func placesAgainstYourCountry(_ country: String, _ places: [String], _ expected: Profile.Eligibility) {
        #expect(me(country).eligibility(for: job(places)) == expected, "\(country) vs \(places)")
    }

    @Test func aProgrammeOrEventAbroadIsNeverExcludedByItsPlace() {
        for kind in [RadarItem.Kind.program, .contest, .hackathon] {
            #expect(me("Vietnam").eligibility(for: job(["Germany"], kind: kind)) == .unclear)
            #expect(me("Vietnam").eligibility(for: job(["Paris, France"], kind: kind)) == .unclear)
            #expect(me("Vietnam").eligibility(for: job(["Worldwide (online)"], kind: kind)) == .fits)
        }
        for country in ["Vietnam", "United States", "Germany", "India", "Atlantis"] {
            for p in Programmes.all { #expect(me(country).eligibility(for: p) != .excluded, "\(country) / \(p.title)") }
        }
        #expect(Profile().eligibility(for: Programmes.all[0]) == .fits)  // worldwide and remote
    }

    @Test(arguments: [
        // needsSponsorship, sponsorship statement, expected (the place is the person's own country)
        (true, "Does Not Offer Sponsorship", Profile.Eligibility.excluded), (true, "U.S. Citizenship is Required", .excluded),
        (true, "Offers Sponsorship", .fits), (true, nil, .unclear), (true, "Other", .unclear),
        (false, "Does Not Offer Sponsorship", .fits), (false, "Offers Sponsorship", .fits), (false, nil, .fits),
        (nil, "Does Not Offer Sponsorship", .unclear), (nil, "Offers Sponsorship", .fits), (nil, nil, .fits),
    ] as [(Bool?, String?, Profile.Eligibility)])
    func sponsorshipAgainstYourNeed(_ needs: Bool?, _ statement: String?, _ expected: Profile.Eligibility) {
        #expect(me("United States", sponsor: needs).eligibility(for: job(["New York, NY"], sponsorship: statement)) == expected, "\(String(describing: needs)) / \(String(describing: statement))")
    }

    @Test func sponsorshipDoesNotRescueAWrongPlace() {
        #expect(me("Vietnam", sponsor: true).eligibility(for: job(["New York, NY"], sponsorship: "Offers Sponsorship")) == .excluded)
    }

    @Test func citizenshipOnlyPostingsLookAtYourCitizenship() {
        let us = job(["New York, NY"], sponsorship: "U.S. Citizenship is Required")
        #expect(me("United States", citizen: "United States", sponsor: false).eligibility(for: us) == .fits)
        #expect(me("United States", citizen: "USA", sponsor: false).eligibility(for: us) == .fits)
        #expect(me("United States", citizen: "Vietnam", sponsor: false).eligibility(for: us) == .excluded)
        #expect(me("United States", citizen: nil, sponsor: false).eligibility(for: us) == .unclear)
        #expect(me("United States", citizen: "Atlantis", sponsor: false).eligibility(for: us) == .unclear)
        #expect(me("United States", citizen: "Vietnam", sponsor: nil).eligibility(for: us) == .excluded)
    }

    @Test func aRemotePreferenceOnlyExcludesAKnownConflict() {
        let onsite = job(["Remote"], remote: false), remote = job(["Remote"], remote: true), either = job(["Remote"], remote: nil)
        #expect(me(remote: true).eligibility(for: onsite) == .excluded && me(remote: true).eligibility(for: remote) == .fits)
        #expect(me(remote: false).eligibility(for: remote) == .excluded && me(remote: false).eligibility(for: onsite) == .fits)
        #expect(me(remote: true).eligibility(for: either) == .fits && me(remote: false).eligibility(for: either) == .fits)
        #expect(me(remote: nil).eligibility(for: onsite) == .fits && me(remote: nil).eligibility(for: remote) == .fits)
        // a programme held on site is excluded for someone who wants remote only
        let daad = Programmes.all.first { $0.host == "daad.de" }!
        #expect(me(remote: true).eligibility(for: daad) == .excluded && me(remote: nil).eligibility(for: daad) == .unclear)
    }

    @Test func theLineTheCardShows() {
        #expect(Profile.Eligibility.unclear.note == "eligibility unclear, check")
        #expect(Profile.Eligibility.fits.note == "fits what you told Robo" && Profile.Eligibility.excluded.note == "outside what you told Robo")
    }

    @Test func aRealSimplifyShapedListingAgainstARealProfile() throws {
        let listing = try #require(Feeds.simplify(Data(#"[{"company_name":"Western Digital","title":"Intern","active":true,"is_visible":true,"url":"https://jobs.smartrecruiters.com/WesternDigital/1","locations":["San Jose, CA","Remote in USA"],"sponsorship":"Does Not Offer Sponsorship"}]"#.utf8)).first)
        #expect(me("United States", sponsor: true).eligibility(for: listing) == .excluded)
        #expect(me("United States", sponsor: false).eligibility(for: listing) == .fits)
        #expect(me("Vietnam", sponsor: false).eligibility(for: listing) == .excluded)
        #expect(Profile().eligibility(for: listing) == .unclear)
    }
}
