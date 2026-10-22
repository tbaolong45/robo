// The radar's feed parsers (pure): each source's real shape (trimmed samples fetched 2026-10-20, Lever's from its docs), the
// entries that must be dropped, and hostile input (HTML in text, bad URLs, giant fields, malformed JSON, entity bombs).
// No network: every fixture is inline.
import Foundation
import Testing
@testable import RoboCore

private func data(_ s: String) -> Data { Data(s.utf8) }

private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

/// What every parser promises about every item it returns, whatever went in.
private func holds(_ items: [RadarItem], sourceLocation: SourceLocation = #_sourceLocation) {
    for i in items {
        #expect(i.url.hasPrefix("https://") && !i.url.contains(" "), "url \(i.url)", sourceLocation: sourceLocation)
        #expect(!i.title.isEmpty && i.title.count <= 200, sourceLocation: sourceLocation)
        #expect(i.snippet.count <= 300 && i.tags.count <= 8 && i.location.count <= 6, sourceLocation: sourceLocation)
        #expect((0.0...1.0).contains(i.trust), sourceLocation: sourceLocation)
        #expect(!i.id.isEmpty && !i.source.isEmpty && !i.host.isEmpty, sourceLocation: sourceLocation)
        for text in [i.title, i.snippet, i.source] + i.tags {
            #expect(!text.contains("<") || !text.contains(">"), "tags left in \(text)", sourceLocation: sourceLocation)
            #expect(!text.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format },
                    sourceLocation: sourceLocation)
        }
        if i.isOpportunity { #expect(i.deadline != nil || i.deadlineNote != nil, sourceLocation: sourceLocation) }
    }
}

// MARK: fixtures

private let arxivFeed = """
<?xml version='1.0' encoding='UTF-8'?>
<feed xmlns:arxiv="http://arxiv.org/schemas/atom" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns="http://www.w3.org/2005/Atom" xml:lang="en-us">
  <id>http://rss.arxiv.org/atom/cs.CV</id>
  <title>cs.CV updates on arXiv.org</title>
  <updated>2026-10-19T04:00:34.864776+00:00</updated>
  <link href="http://rss.arxiv.org/atom/cs.CV" rel="self" type="application/atom+xml"/>
  <subtitle>cs.CV updates on the arXiv.org e-print archive.</subtitle>
  <entry>
    <id>oai:arXiv.org:2610.22444v1</id>
    <title>Event-STVG: Spatio-Temporal Video Grounding for Long-Form Event Reasoning</title>
    <updated>2026-10-19T04:00:34.864860+00:00</updated>
    <link href="https://arxiv.org/abs/2610.22444" rel="alternate" type="text/html"/>
    <summary>arXiv:2610.22444v1 Announce Type: new
Abstract: Spatio-Temporal Video Grounding (STVG) aims to jointly localize a target in space and time given a natural-language query. Despite continued advances, existing STVG benchmarks remain largely centered on localizing targets through instance-specific descriptions, leaving them largely decoupled from long-form reasoning increasingly emphasized in multimodal large language models (MLLMs). In this paper, we introduce Event-STVG, a task that shifts STVG from locating what is described toward event-level reasoning. Code and annotations are available at https://github.com/THU-KEG/EventSTVG</summary>
    <category term="cs.CV"/>
    <published>2026-10-19T00:00:00-04:00</published>
    <arxiv:announce_type>new</arxiv:announce_type>
    <dc:rights>http://creativecommons.org/licenses/by/4.0/</dc:rights>
    <dc:creator>Ada Author, Bob Writer</dc:creator>
  </entry>
  <entry>
    <id>oai:arXiv.org:2610.22474v1</id>
    <title>Star Light, Star Bright: Can Multimodal Models Parse an Astronomy Visual Question Answering Dataset Right?</title>
    <updated>2026-10-19T04:00:34.864960+00:00</updated>
    <link href="https://arxiv.org/abs/2610.22474" rel="alternate" type="text/html"/>
    <summary>arXiv:2610.22474v1 Announce Type: new
Abstract: Figures are essential for scientific communication. All code is available on GitHub.</summary>
    <category term="cs.CV"/>
    <category term="astro-ph.IM"/>
    <category term="cs.DL"/>
    <category term="cs.IR"/>
    <published>2026-10-19T00:00:00-04:00</published>
    <arxiv:announce_type>new</arxiv:announce_type>
    <dc:creator>J. P. Naiman</dc:creator>
  </entry>
  <entry>
    <id>oai:arXiv.org:2501.00001v3</id>
    <title>An old paper that was replaced</title>
    <link href="https://arxiv.org/abs/2501.00001" rel="alternate" type="text/html"/>
    <summary>arXiv:2501.00001v3 Announce Type: replace
Abstract: Replaced.</summary>
    <category term="cs.CV"/>
    <arxiv:announce_type>replace</arxiv:announce_type>
  </entry>
  <entry>
    <id>oai:arXiv.org:2501.00002v2</id>
    <title>An old paper replaced across lists</title>
    <link href="https://arxiv.org/abs/2501.00002" rel="alternate" type="text/html"/>
    <summary>arXiv:2501.00002v2 Announce Type: replace-cross
Abstract: Replaced.</summary>
    <arxiv:announce_type>replace-cross</arxiv:announce_type>
  </entry>
  <entry>
    <id>oai:arXiv.org:2610.30000v1</id>
    <title>A cross-list from another category</title>
    <link href="https://arxiv.org/abs/2610.30000" rel="alternate" type="text/html"/>
    <summary>arXiv:2610.30000v1 Announce Type: cross
Abstract: Cross-listed.</summary>
    <arxiv:announce_type>cross</arxiv:announce_type>
  </entry>
</feed>
"""

private let hfJSON = #"""
[{"paper":{"id":"2610.19432","authors":[{"_id":"6ad6267902d0b6d70f1d6737","name":"Ada Author","hidden":false}],"publishedAt":"2026-10-14T00:00:00.000Z","submittedOnDailyAt":"2026-10-19T00:00:00.000Z","title":"Recognition Is Not Grounding: Benchmarking Multilingual Financial Evidence Extraction","summary":"Comparing financial disclosures across languages requires identifying shared accounting concepts.","upvotes":1,"discussionId":"6ad6267902d0b6d70f1d673f","ai_summary":"The study introduces MULTIFINGROUND, a multilingual benchmark showing that language models struggle to ground evidence.","ai_keywords":["MULTIFINGROUND","multilingual financial reports","accounting taxonomy"],"ai_summary_model":"x","organization":{"_id":"658f","name":"TheFinAI","fullname":"The Fin AI"}},"publishedAt":"2026-10-13T20:00:00.000Z","title":"Recognition Is Not Grounding: Benchmarking Multilingual Financial Evidence Extraction","summary":"Comparing financial disclosures across languages.","numComments":1,"isAuthorParticipating":false},{"paper":{"id":"2610.07052","publishedAt":"2026-10-05T00:00:00.000Z","title":"BRACE: Adapting Whole-Body References for Force and Terrain Aware Humanoid Motion Tracking","summary":"A whole-body tracker.","upvotes":2,"githubRepo":"https://github.com/multiplylabs/brace","githubStars":16,"projectPage":"https://multiplylabs.github.io/brace/","ai_summary":"BRACE is a whole-body humanoid tracker that integrates commanded hand forces and terrain adaptation.","ai_keywords":["whole-body tracking","force-capable policies","terrain-adaptive trackers","wrench transformation","center-of-mass","center-of-pressure","DAgger"]},"publishedAt":"2026-10-05T10:00:00.000Z","title":"BRACE","summary":"x"}]
"""#

private let hnDropbox = #"""
{"by":"dhouston","descendants":71,"id":8863,"kids":[9224,8917,8884],"score":104,"time":1175714200,"title":"My YC app: Dropbox - Throw away your USB drive","type":"story","url":"http://www.getdropbox.com/u/2/screencast.html"}
"""#

private let mitRSS = """
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:atom="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:media="http://search.yahoo.com/mrss/" xmlns:content="http://purl.org/rss/1.0/modules/content/" version="2.0" xml:base="https://news.mit.edu">
  <channel>
    <title>MIT News - Artificial intelligence</title>
    <link>https://news.mit.edu/rss/topic/artificial-intelligence2</link>
    <atom:link href="https://news.mit.edu/rss/topic/artificial-intelligence2" rel="self" type="application/rss+xml"/>
    <description>MIT news feed about: Artificial intelligence</description>
    <language>en</language>
    <lastBuildDate>Fri, 16 Oct 2026 12:00:00 -0400</lastBuildDate>
    <item>
  <title>Why teaching AI about symmetry could make prenatal diagnosis more reliable</title>
  <link>https://news.mit.edu/2026/teaching-ai-about-symmetry-could-make-prenatal-diagnosis-more-reliable-1019</link>
  <description>A model developed by researchers at MIT and Boston Children's Hospital adjusts scans on the fly to track fetal movement.</description>
  <pubDate>Mon, 19 Oct 2026 14:20:00 -0400</pubDate>
    <guid isPermaLink="true">https://news.mit.edu/2026/teaching-ai-about-symmetry-could-make-prenatal-diagnosis-more-reliable-1019</guid>
        <dc:creator>Alex Ouyang | Abdul Latif Jameel Clinic for Machine Learning in Health</dc:creator>
  <content:encoded>&lt;p dir="ltr"&gt;Despite millions of years of evolution, the development of the human fetus remains complex.&amp;nbsp;&lt;/p&gt;</content:encoded>
  <category>Artificial intelligence</category>
  <category>Imaging</category>
    </item>
    <item>
  <title>A second story</title>
  <link>https://news.mit.edu/2026/second</link>
  <description>&lt;p&gt;Escaped &lt;b&gt;markup&lt;/b&gt; &amp;amp; entities&lt;/p&gt;</description>
  <pubDate>Sun, 18 Oct 2026 09:00:00 GMT</pubDate>
    </item>
  </channel>
</rss>
"""

private let rustAtom = """
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en">
    <generator uri="https://blog.rust-lang.org/" version="0.1.0">Rust Blog</generator>
    <link href="https://blog.rust-lang.org/feed.xml" rel="self" type="application/atom+xml" />
    <link href="https://blog.rust-lang.org/" rel="alternate" type="text/html" />
    <id>https://blog.rust-lang.org/</id>
    <title>Rust Blog</title>
    <author>
        <name>Maintained by the Rust Teams.</name>
        <uri>https://github.com/rust-lang/blog.rust-lang.org/</uri>
    </author>
    <updated>2026-10-19T12:36:35+00:00</updated>
    <entry>
        <title>Announcing Rust 1.99.1</title>
        <link rel="alternate" href="https://blog.rust-lang.org/2026/10/15/Rust-1.99.1/" type="text/html" title="Announcing Rust 1.99.1" />
        <published>2026-10-15T00:00:00+00:00</published>
        <updated>2026-10-15T00:00:00+00:00</updated>
        <id>https://blog.rust-lang.org/2026/10/15/Rust-1.99.1/</id>
        <content type="html" xml:base="https://blog.rust-lang.org/2026/10/15/Rust-1.99.1/">&lt;p&gt;The Rust team has published a new point release of Rust, 1.99.1.&lt;/p&gt;
&lt;pre class&#x3D;&quot;giallo&quot; &gt;&lt;code data-lang&#x3D;&quot;plain&quot;&gt;rustup update stable&lt;/code&gt;&lt;/pre&gt;
&lt;p&gt;If you don&#x27;t have it already, you can &lt;a rel&#x3D;&quot;external&quot; href&#x3D;&quot;https://www.rust-lang.org/install.html&quot;&gt;get &lt;code&gt;rustup&lt;/code&gt;&lt;/a&gt; from the website.&lt;/p&gt;</content>
    </entry>
</feed>
"""

private let simplifyJSON = #"""
[
 {"source":"Simplify","category":"Hardware","company_name":"Analog Devices","id":"e501f0b7","title":"Reliability Operations Engineer Co-Op","active":false,"terms":["Summer 2026","Fall 2026"],"date_updated":1771717305,"date_posted":1771717305,"url":"https://analogdevices.wd1.myworkdayjobs.com/External/job/US-MA-Wilmington/R256591","locations":["Burlington, MA"],"company_url":"https://simplify.jobs/c/Analog-Devices","is_visible":true,"sponsorship":"Other","degrees":["Bachelor's","Master's"]},
 {"source":"Simplify","category":"AI/ML/Data","company_name":"Western Digital","id":"0d1a1aa2","title":"2026 Summer Intern - Data Engineering","active":true,"terms":["Summer 2027"],"date_updated":1791744178,"date_posted":1791744178,"url":"https://jobs.smartrecruiters.com/WesternDigital/744000110544134?utm_source=Simplify&ref=Simplify","locations":["San Jose, CA","Remote in USA"],"company_url":"https://simplify.jobs/c/Western-Digital","is_visible":true,"sponsorship":"Does Not Offer Sponsorship","degrees":["Bachelor's","Master's"]},
 {"source":"Simplify","category":"Software","company_name":"Hidden Co","id":"h1","title":"Hidden Intern","active":true,"date_posted":1791744178,"url":"https://example.com/hidden","locations":["Berlin, Germany"],"is_visible":false,"sponsorship":"Other"},
 {"source":"Simplify","category":"Software","company_name":"Open Co","id":"o1","title":"Research Intern","active":true,"date_posted":1791744178,"url":"https://example.com/open","locations":[],"is_visible":true,"sponsorship":"Offers Sponsorship","terms":["Summer 2027"]},
 {"source":"Simplify","company_name":"No Link Co","id":"n1","title":"Intern","active":true,"is_visible":true,"url":"http://example.com/insecure"},
 {"company_name":"No Title Co","active":true,"url":"https://example.com/x"}
]
"""#

private let greenhouseJSON = #"""
{"jobs":[
 {"absolute_url":"https://job-boards.greenhouse.io/anthropic/jobs/5456619008","data_compliance":[{"type":"gdpr","requires_consent":false}],"internal_job_id":4563891008,"location":{"name":"San Francisco, CA | Seattle, WA"},"metadata":[{"id":4036944008,"name":"Location Type","value":"On-Site","value_type":"single_select"}],"id":5456619008,"updated_at":"2026-10-19T11:17:24-04:00","requisition_id":"REQ-26-1145-01","title":"3P Revenue Accounting & Reporting","company_name":"Anthropic","first_published":"2026-10-19T11:17:24-04:00","language":"en","application_deadline":null},
 {"absolute_url":"https://job-boards.greenhouse.io/anthropic/jobs/5391376008","internal_job_id":4533087008,"location":{"name":"New York City, NY; San Francisco, CA | New York City, NY"},"metadata":[{"id":4036944008,"name":"Location Type","value":"Remote","value_type":"single_select"}],"id":5391376008,"updated_at":"2026-10-12T09:00:00-04:00","requisition_id":"3356","title":"Research Engineer Intern, Summer 2027","company_name":"Anthropic","first_published":"2026-10-10T13:53:38-05:00","language":"en","application_deadline":"2026-12-01T23:59:00-05:00"},
 {"absolute_url":"https://job-boards.greenhouse.io/anthropic/jobs/1","location":{"name":"Singapore"},"id":1,"updated_at":"2026-10-12T09:00:00-04:00","title":"Internal Tools Engineer","company_name":"Anthropic"},
 {"absolute_url":"javascript:alert(1)","location":{"name":"Remote"},"id":2,"title":"Software Engineering Intern","company_name":"Anthropic"}
],"meta":{"total":4}}
"""#

// Lever's shape comes from its postings API docs: the live sample was cut off before `categories`.
private let leverJSON = #"""
[
 {"additionalPlain":"Life at Example","additional":"<p>Life at Example</p>","categories":{"commitment":"Intern","department":"Engineering","location":"Palo Alto, CA","team":"Machine Learning","allLocations":["Palo Alto, CA","Remote"]},"country":"US","createdAt":1791744178000,"descriptionPlain":"Join the <b>ML</b> team for the summer.\nYou will train models.","description":"<div>Join</div>","id":"0f1f7a26-1111-2222-3333-444444444444","lists":[],"text":"Machine Learning Engineer","workplaceType":"hybrid","hostedUrl":"https://jobs.lever.co/example/0f1f7a26-1111-2222-3333-444444444444","applyUrl":"https://jobs.lever.co/example/0f1f7a26-1111-2222-3333-444444444444/apply"},
 {"categories":{"commitment":"Full-time","location":"Remote"},"createdAt":1791744178000,"id":"b","text":"Senior Platform Engineer","hostedUrl":"https://jobs.lever.co/example/b"},
 {"categories":{"commitment":"Full-time","location":"London"},"createdAt":1791744178000,"id":"c","text":"Summer Intern, Research","workplaceType":"remote","hostedUrl":"http://jobs.lever.co/example/c","applyUrl":"https://jobs.lever.co/example/c/apply"}
]
"""#

private let ashbyJSON = #"""
{"jobs":[
 {"id":"8fb1615c","title":"Technical Program Manager, Compute Infrastructure","department":"Technical Program Management","team":"Technical Program Management","employmentType":"FullTime","location":"San Francisco","secondaryLocations":[],"publishedAt":"2026-03-12T16:38:15.322+00:00","isListed":true,"isRemote":null,"workplaceType":null,"address":{"postalAddress":{"addressRegion":"California","addressCountry":"United States","addressLocality":"San Francisco"}},"jobUrl":"https://jobs.ashbyhq.com/openai/8fb1615c","applyUrl":"https://jobs.ashbyhq.com/openai/8fb1615c/application","descriptionHtml":"<h3><strong>About the Team</strong></h3><p>The compute team.</p>"},
 {"id":"a1","title":"Research Intern","department":"Research","team":"Alignment","employmentType":"Intern","location":"London","secondaryLocations":[{"location":"Remote - UK"}],"publishedAt":"2026-10-01T08:00:00.000+00:00","isListed":true,"isRemote":true,"workplaceType":"Remote","jobUrl":"https://jobs.ashbyhq.com/openai/a1","applyUrl":"https://jobs.ashbyhq.com/openai/a1/application","descriptionPlain":"Work on <i>research</i>.","descriptionHtml":"<p>Work on research.</p>"},
 {"id":"a2","title":"Research Intern (unlisted)","employmentType":"Intern","location":"London","isListed":false,"jobUrl":"https://jobs.ashbyhq.com/openai/a2"},
 {"id":"a3","title":"Data Science Placement","employmentType":"Intern","location":"Paris","isListed":true,"isRemote":false,"jobUrl":"https://jobs.ashbyhq.com/openai/a3"}
]}
"""#

private let ctfJSON = #"""
[{"organizers": [{"id": 448857, "name": "pulse_0x1337"}], "ctftime_url": "https://ctftime.org/event/3451/", "ctf_id": 1703, "weight": 0.00, "duration": {"hours": 4, "days": 1}, "live_feed": "", "logo": "https://ctftime.org//media/events/logo-brc.jpg", "id": 3451, "title": "BreachPoint 2026", "start": "2026-09-25T04:00:00+00:00", "participants": 32, "location": "PSG College of Technology, Coimbatore, Tamil Nadu", "finish": "2026-09-26T08:30:00+00:00", "description": "Breach Point is a cybersecurity Capture the Flag (CTF) event designed to challenge participants through two intense rounds of problem-solving and hands-on security. It follows a Jeopardy-style format.", "format": "Jeopardy", "is_votable_now": false, "prizes": "Prize Pool of 17,500", "format_id": 1, "onsite": true, "restrictions": "Open", "url": "https://breachpoint.axios.live/", "public_votable": false}, {"organizers": [{"id": 374041, "name": "CyberXoX"}], "ctftime_url": "https://ctftime.org/event/3454/", "ctf_id": 1633, "weight": 23.5, "duration": {"hours": 12, "days": 0}, "live_feed": "https://ctftime.org/live/3454/", "id": 3454, "title": "Null Origin CTF 2026: Grand finale ", "start": "2026-09-25T04:30:00+00:00", "participants": 23, "location": "", "finish": "2026-09-25T16:30:00+00:00", "description": "Null Origin CTF 2026 — Grand Finale\r\n\r\nNull Origin is an international online Capture The Flag competition.\r\n• Duration: 12 Hours\r\n• Mode: Online", "format": "Jeopardy", "onsite": false, "restrictions": "Prequalified", "url": "javascript:alert(1)"}, {"id": 9, "title": "No ctftime link", "start": "2026-09-25T04:30:00+00:00", "url": "https://elsewhere.example/", "onsite": false, "restrictions": "Open"}]
"""#

private let codeforcesJSON = #"""
{"status":"OK","result":[{"id":2278,"name":"Codeforces Round (Div. 3)","type":"ICPC","phase":"BEFORE","frozen":false,"durationSeconds":8100,"startTimeSeconds":1793457300,"relativeTimeSeconds":-1009637},{"id":2272,"name":"Codeforces Round (Div. 2)","type":"CF","phase":"BEFORE","frozen":false,"durationSeconds":7200,"startTimeSeconds":1793025300,"relativeTimeSeconds":-577637},{"id":2277,"name":"Codeforces Round (Div. 2)","type":"CF","phase":"BEFORE","frozen":false,"durationSeconds":7200,"startTimeSeconds":1792839900,"relativeTimeSeconds":-392237},{"id":2261,"name":"WorldQuant Round 1 (Codeforces Round 1128, Div. 1 + Div. 2)","type":"CF","phase":"FINISHED","frozen":false,"durationSeconds":10800,"startTimeSeconds":1792247700,"relativeTimeSeconds":199963},{"id":2276,"name":"Educational Codeforces Round 195 (Rated for Div. 2)","type":"ICPC","phase":"CODING","frozen":false,"durationSeconds":7200,"startTimeSeconds":1791988500,"relativeTimeSeconds":459163}]}
"""#

// MARK: arXiv

@Suite struct ArxivParserTests {
    @Test func newPapersCarryTheirIdLinkTagsAndDateAndNoAuthors() throws {
        let items = Feeds.arxiv(data(arxivFeed))
        holds(items)
        #expect(items.map(\.id) == ["arxiv:2610.22444", "arxiv:2610.22474"])
        let first = items[0]
        #expect(first.kind == .paper && first.source == "arXiv" && first.trust == 0.85 && first.popularity == nil)
        #expect(first.url == "https://arxiv.org/abs/2610.22444" && first.host == "arxiv.org")
        #expect(first.title == "Event-STVG: Spatio-Temporal Video Grounding for Long-Form Event Reasoning")
        #expect(first.tags == ["cs.CV"] && items[1].tags == ["cs.CV", "astro-ph.IM", "cs.DL", "cs.IR"])
        #expect(first.published == at("2026-10-19T04:00:00Z"))  // 00:00 at -04:00
        #expect(first.deadlineNote == nil)
        let everything = items.map { "\($0)" }.joined()
        #expect(!everything.contains("Ada Author") && !everything.contains("Naiman"))
    }

    @Test func theSnippetLosesItsAnnounceTypeLeadAndIsCapped() {
        let items = Feeds.arxiv(data(arxivFeed))
        #expect(items[0].snippet.hasPrefix("Spatio-Temporal Video Grounding (STVG) aims to jointly localize"))
        #expect(items[0].snippet.count <= 300 && items[0].snippet.hasSuffix("…"))
        #expect(items[1].snippet == "Figures are essential for scientific communication. All code is available on GitHub.")
    }

    @Test func replacementsAndCrossListsAreNotNew() {
        let ids = Feeds.arxiv(data(arxivFeed)).map(\.id)
        #expect(!ids.contains("arxiv:2501.00001") && !ids.contains("arxiv:2501.00002") && !ids.contains("arxiv:2610.30000"))
    }

    @Test func aFeedWithoutAnnounceTypesIsKept() {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>http://arxiv.org/abs/2610.00001v2</id><title>No type</title>\
        <link href="https://arxiv.org/abs/2610.00001v2"/><summary>S</summary></entry></feed>
        """
        let items = Feeds.arxiv(data(xml))
        #expect(items.map(\.id) == ["arxiv:2610.00001"] && items[0].url == "https://arxiv.org/abs/2610.00001")
    }

    @Test func aWholeMailingIsCappedAtFourHundredEntriesAndStopsEarly() {
        var xml = "<feed xmlns=\"http://www.w3.org/2005/Atom\">"
        for n in 0..<450 {
            let id = String(format: "2610.%05d", n)
            xml += "<entry><id>oai:arXiv.org:\(id)v1</id><title>Paper \(n)</title><link href=\"https://arxiv.org/abs/\(id)\" rel=\"alternate\"/><summary>S \(n)</summary></entry>"
        }
        xml += "</feed>"
        let items = Feeds.arxiv(data(xml))
        #expect(items.count == Feeds.arxivCap && Feeds.arxivCap == 400)
        #expect(items.first?.id == "arxiv:2610.00000" && items.last?.id == "arxiv:2610.00399")
    }

    @Test func entriesWithoutATitleOrAUsableIdAreDropped() {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">\
        <entry><id>oai:arXiv.org:2610.00001v1</id><title>   </title><link href="https://arxiv.org/abs/2610.00001"/></entry>\
        <entry><id>not an arxiv id</id><title>Bad id</title><link href="https://example.com/abs/2610.00002"/></entry>\
        <entry><id>oai:arXiv.org:2610.00003v1</id><link href="https://arxiv.org/abs/2610.00003"/></entry>\
        <entry><id>oai:arXiv.org:2610.00004v1</id><title>Fine</title><link href="javascript:alert(1)"/></entry>\
        </feed>
        """
        // The last one has a hostile link but a valid id: the URL is built from the id, so it is safe and kept.
        let items = Feeds.arxiv(data(xml))
        #expect(items.map(\.id) == ["arxiv:2610.00004"] && items[0].url == "https://arxiv.org/abs/2610.00004")
    }

    @Test func htmlInTheTitleAndSummaryIsStripped() {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>oai:arXiv.org:2610.00005v1</id>\
        <title>&lt;script&gt;alert(1)&lt;/script&gt;Safe &lt;b&gt;title&lt;/b&gt;</title>\
        <link href="https://arxiv.org/abs/2610.00005"/>\
        <summary>arXiv:2610.00005v1 Announce Type: new\nAbstract: Text with <![CDATA[<img src=x onerror=alert(1)>]]> inside and $a &lt; b$ math.</summary></entry></feed>
        """
        let item = Feeds.arxiv(data(xml)).first
        #expect(item?.title == "Safe title")
        #expect(item?.snippet == "Text with inside and $a < b$ math.")
    }
}

// MARK: Hugging Face

@Suite struct HuggingFaceParserTests {
    @Test func upvotesAreThePopularityAndTheAISummaryIsTheSnippet() {
        let items = Feeds.huggingFacePapers(data(hfJSON))
        holds(items)
        #expect(items.map(\.id) == ["arxiv:2610.19432", "arxiv:2610.07052"])
        #expect(items[0].popularity == 1 && items[1].popularity == 2)
        #expect(items[0].snippet.hasPrefix("The study introduces MULTIFINGROUND"))
        #expect(items[0].url == "https://arxiv.org/abs/2610.19432" && items[0].source == "Hugging Face" && items[0].kind == .paper)
        #expect(items[0].published == at("2026-10-14T00:00:00Z"))
    }

    @Test func keywordsAreTagsAndALinkedRepoAddsCode() {
        let items = Feeds.huggingFacePapers(data(hfJSON))
        #expect(items[0].tags == ["MULTIFINGROUND", "multilingual financial reports", "accounting taxonomy"])
        // the first five keywords of seven, then "code": this paper links a repo
        #expect(items[1].tags == ["whole-body tracking", "force-capable policies", "terrain-adaptive trackers", "wrench transformation", "center-of-mass", "code"])
        let withCode = Feeds.huggingFacePapers(data(#"[{"paper":{"id":"2610.00009","title":"T","githubRepo":"https://github.com/a/b","githubStars":3,"ai_keywords":["x"]}}]"#))
        #expect(withCode.first?.tags == ["x", "code"])
    }

    @Test func theSameIdAsTheArxivFeedSoTheyMergeLater() {
        #expect(Feeds.huggingFacePapers(data(hfJSON)).first?.id == Feeds.arxiv(data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>oai:arXiv.org:2610.19432v1</id><title>T</title><link href="https://arxiv.org/abs/2610.19432"/></entry></feed>
        """)).first?.id)
    }

    @Test func wrongTypesAndMissingPartsDropOnlyThatEntry() {
        let json = #"[{"paper":"x"},{"paper":{"id":5}},{"paper":{"id":"not-an-id","title":"t"}},{"paper":{"id":"2610.00001"}},7,null,"s",{"paper":{"id":"2610.00002","title":"Good","upvotes":"12"}}]"#
        let items = Feeds.huggingFacePapers(data(json))
        #expect(items.map(\.id) == ["arxiv:2610.00002"] && items[0].popularity == 12)
    }
}

// MARK: Hacker News

@Suite struct HackerNewsParserTests {
    @Test func aStoryWithAnHttpLinkFallsBackToItsDiscussionPage() throws {
        let items = Feeds.hackerNews(data(hnDropbox))
        holds(items)
        let item = try #require(items.first)
        #expect(item.url == "https://news.ycombinator.com/item?id=8863" && item.id == "https://news.ycombinator.com/item?id=8863")
        #expect(item.title == "My YC app: Dropbox - Throw away your USB drive" && item.popularity == 104)
        #expect(item.kind == .news && item.source == "Hacker News" && item.published == Date(timeIntervalSince1970: 1_175_714_200))
    }

    @Test func aStoryWithAnHttpsLinkKeepsItAndDropsTracking() {
        let json = #"{"id":1,"type":"story","title":"Neat","url":"https://Example.com/post/?utm_source=hn&id=7","score":50,"time":1790000000}"#
        let item = Feeds.hackerNews(data(json)).first
        #expect(item?.url == "https://Example.com/post/?utm_source=hn&id=7")
        #expect(item?.id == "https://example.com/post?id=7")
    }

    @Test func aStoryThatLinksToAPaperIsThePaper() {
        let json = #"{"id":2,"type":"story","title":"A paper","url":"https://arxiv.org/pdf/2610.22444v2.pdf","score":9,"time":1790000000}"#
        #expect(Feeds.hackerNews(data(json)).first?.id == "arxiv:2610.22444")
    }

    @Test func askHNPollsCommentsAndDeadItemsAreSkipped() {
        let items = [
            #"{"id":3,"type":"story","title":"Ask HN: how do you study?","text":"Hello","score":5,"time":1790000000}"#,
            #"{"id":4,"type":"poll","title":"Poll","url":"https://example.com/p"}"#,
            #"{"id":5,"type":"comment","text":"hi"}"#,
            #"{"id":6,"type":"story","title":"Dead","url":"https://example.com/d","dead":true}"#,
            #"{"id":7,"type":"story","title":"Deleted","url":"https://example.com/e","deleted":true}"#,
            #"{"id":8,"type":"story","url":"https://example.com/no-title"}"#,
            #"{"id":9,"type":"story","title":"Empty link","url":""}"#,
        ]
        for json in items { #expect(Feeds.hackerNews(data(json)).isEmpty, "\(json)") }
    }

    @Test func aJobWithALinkIsKeptAndSeveralItemsInAnArrayAreAllRead() {
        let json = #"[{"id":10,"type":"job","title":"Acme is hiring","url":"https://acme.example/jobs","time":1790000000},{"id":11,"type":"story","title":"Two","url":"https://example.com/2","score":1},null,5]"#
        #expect(Feeds.hackerNews(data(json)).map(\.title) == ["Acme is hiring", "Two"])
    }

    @Test func theTopStoriesListGivesTheFirstValidIds() {
        #expect(Feeds.hackerNewsIDs(data("[50158100,50154540,50150089,50152307]"), limit: 3) == [50158100, 50154540, 50150089])
        #expect(Feeds.hackerNewsIDs(data(#"[1,"x",4.5,-7,0,2,null]"#)) == [1, 2])
        #expect(Feeds.hackerNewsIDs(data("[1,2,3]"), limit: -1).isEmpty)
        #expect(Feeds.hackerNewsIDs(data(#"{"a":1}"#)).isEmpty && Feeds.hackerNewsIDs(data("junk")).isEmpty)
    }

    @Test func anHugeIdDoesNotTrap() {
        #expect(Feeds.hackerNews(data(#"{"id":1e999,"type":"story","title":"t","url":"https://a.com/x"}"#)).isEmpty)
        #expect(Feeds.hackerNews(data(#"{"id":1e30,"type":"story","title":"t","url":"https://a.com/x"}"#)).isEmpty)
        #expect(Feeds.hackerNewsIDs(data("[1e30, 5]")) == [5])
    }
}

// MARK: RSS and Atom news

@Suite struct NewsParserTests {
    @Test func anRSSItemGivesTitleLinkDateAndAPlainSnippet() {
        let items = Feeds.news(data(mitRSS), source: "MIT News")
        holds(items)
        #expect(items.count == 2)
        let first = items[0]
        #expect(first.title == "Why teaching AI about symmetry could make prenatal diagnosis more reliable")
        #expect(first.url == "https://news.mit.edu/2026/teaching-ai-about-symmetry-could-make-prenatal-diagnosis-more-reliable-1019")
        #expect(first.snippet == "A model developed by researchers at MIT and Boston Children's Hospital adjusts scans on the fly to track fetal movement.")
        #expect(first.published == at("2026-10-19T18:20:00Z"))
        #expect(first.tags == ["Artificial intelligence", "Imaging"] && first.source == "MIT News" && first.kind == .news && first.trust == 0.6)
        #expect(!"\(first)".contains("Ouyang"))  // the byline is not kept
    }

    @Test func escapedMarkupInADescriptionIsStrippedAndGMTDatesParse() {
        let second = Feeds.news(data(mitRSS))[1]
        #expect(second.snippet == "Escaped markup & entities")
        #expect(second.published == at("2026-10-18T09:00:00Z"))
        #expect(second.source == "news.mit.edu")  // no name given: the domain
    }

    @Test func anAtomEntryUsesItsAlternateLinkAndFlattensItsContent() {
        let items = Feeds.news(data(rustAtom))
        holds(items)
        #expect(items.count == 1)
        #expect(items[0].url == "https://blog.rust-lang.org/2026/10/15/Rust-1.99.1/")
        #expect(items[0].published == at("2026-10-15T00:00:00Z"))
        #expect(items[0].snippet == "The Rust team has published a new point release of Rust, 1.99.1. rustup update stable If you don't have it already, you can get rustup from the website.")
    }

    @Test func onlyAnHttpsLinkSurvives() {
        let links = ["javascript:alert(1)", "http://example.com/a", "//example.com/a", "/relative", "https://user:pw@example.com/",
                     "https://localhost/x", "data:text/html,<b>x</b>", "ftp://example.com/f", "https://example.com/" + String(repeating: "a", count: 3_000),
                     "https://exa mple.com/", "https://example.com/ok"]
        let xml = "<rss><channel>" + links.enumerated().map { "<item><title>t\($0.offset)</title><link>\($0.element)</link></item>" }.joined() + "</channel></rss>"
        #expect(Feeds.news(data(xml)).map(\.url) == ["https://example.com/ok"])
    }

    @Test func aGuidStandsInForAMissingLink() {
        let xml = "<rss><channel><item><title>G</title><guid>https://example.com/g</guid></item><item><title>H</title><guid>urn:uuid:123</guid></item></channel></rss>"
        #expect(Feeds.news(data(xml)).map(\.url) == ["https://example.com/g"])
    }

    @Test func markupInATitleAndADescriptionIsStripped() {
        let xml = """
        <rss><channel><item><title>&lt;script&gt;alert(1)&lt;/script&gt;Real &lt;b&gt;title&lt;/b&gt;</title><link>https://example.com/a</link>\
        <description><![CDATA[<p>Hello <a href="javascript:alert(1)">click</a> world</p><img src=x onerror=alert(1)><style>p{}</style>]]></description></item></channel></rss>
        """
        let item = Feeds.news(data(xml)).first
        #expect(item?.title == "Real title" && item?.snippet == "Hello click world")
    }

    @Test func aGiantFieldIsCappedNotCopied() {
        let xml = "<rss><channel><item><title>" + String(repeating: "A", count: 5_000_000) + "</title><link>https://example.com/big</link>"
            + "<description>" + String(repeating: "word ", count: 400_000) + "</description></item></channel></rss>"
        let item = Feeds.news(data(xml)).first
        #expect(item?.title.count == 200 && item?.title.hasSuffix("…") == true)
        #expect((item?.snippet.count ?? 0) > 250 && (item?.snippet.count ?? 999) <= 300 && item?.snippet.hasSuffix("…") == true)
    }

    @Test func aHundredItemsAtMostComeFromOneFeed() {
        let xml = "<rss><channel>" + (0..<150).map { "<item><title>t\($0)</title><link>https://example.com/\($0)</link></item>" }.joined() + "</channel></rss>"
        #expect(Feeds.news(data(xml)).count == 100)
    }
}

// MARK: internships

// MARK: announcements of labs, and GitHub repositories

/// A search answer as `api.github.com` gave it on 2026-10-23 (three of its ten repositories, cut to the fields robo reads).
private let githubJSON = #"""
{"total_count":26,"incomplete_results":false,"items":[
 {"full_name":"RegeneratusLabs/physical-hermes","description":"Physical Hermes - Give your Hermes Agent a body.","stargazers_count":81,"created_at":"2026-10-18T09:21:40Z","topics":[],"language":null,"fork":false,"archived":false,"private":false},
 {"full_name":"zigansh1n/imnotarobot","description":"I am not a robot - a captcha solver for macOS.","stargazers_count":50,"created_at":"2026-10-19T00:56:29Z","topics":["captcha","gemini","ocr"],"language":"Python","fork":false,"archived":false,"private":false},
 {"full_name":"Shimingyi/awesome-animation-datasets","description":"Every motion dataset in one place.","stargazers_count":41,"created_at":"2026-10-19T10:00:52Z","topics":["robotics","threejs"],"language":"Python","fork":false,"archived":false,"private":false}]}
"""#

@Suite struct AnnouncementParserTests {
    @Test func aLabsBlogIsReadAsAnnouncementsWithMoreTrustThanAFeedTheUserAdded() {
        let items = Feeds.news(data(mitRSS), source: "OpenAI", kind: .announcement)
        holds(items)
        #expect(items.count == 2 && items.allSatisfy { $0.kind == .announcement && $0.source == "OpenAI" && $0.trust == 0.8 })
        #expect(Feeds.news(data(mitRSS), source: "MIT News").allSatisfy { $0.kind == .news && $0.trust == 0.6 })  // the default is unchanged
        #expect(!items[0].isOpportunity && items[0].deadlineNote == nil)  // something to read, not to apply for
    }

    @Test func aLabsBlogThatLinksWithHttpIsReadOverHttpsButAFeedTheUserAddedStaysStrict() {
        // BAIR's feed (2026-10-23): every link is http://bair.berkeley.edu/..., and all ten items were dropped for it
        let feed = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>BAIR</title>
        <item><title>A post</title><link>http://blog.example.edu/post</link><guid>http://blog.example.edu/post</guid><description>x</description>
        <pubDate>Tue, 20 Oct 2026 06:00:00 GMT</pubDate></item></channel></rss>
        """
        #expect(Feeds.news(data(feed), source: "BAIR", kind: .announcement).map(\.url) == ["https://blog.example.edu/post"])
        #expect(Feeds.news(data(feed), source: "mine").isEmpty)  // the user's own feed: an http link is still dropped
        #expect(Feeds.news(data(feed.replacingOccurrences(of: "http://", with: "ftp://")), source: "BAIR", kind: .announcement).isEmpty)  // only http is upgraded
    }
}

@Suite struct GitHubParserTests {
    @Test func aSearchAnswerIsRepositoriesWithStarsTopicsAndTheirOwnLink() {
        let items = Feeds.githubRepos(data(githubJSON))
        holds(items)
        #expect(items.map(\.id) == ["github:regeneratuslabs/physical-hermes", "github:zigansh1n/imnotarobot", "github:shimingyi/awesome-animation-datasets"])
        let second = items[1]
        #expect(second.kind == .repo && second.title == "zigansh1n/imnotarobot" && second.url == "https://github.com/zigansh1n/imnotarobot")
        #expect(second.source == "GitHub" && second.popularity == 50 && second.snippet == "I am not a robot - a captcha solver for macOS.")
        #expect(second.tags == ["captcha", "gemini", "ocr", "Python"] && second.published == at("2026-10-19T00:56:29Z") && second.trust == 0.5)
        #expect(items[0].tags.isEmpty)  // no topics and no language (null)
        #expect(!second.isOpportunity && second.deadlineNote == nil)
    }

    @Test func theLinkIsBuiltFromTheNameNeverTakenFromTheAnswer() {
        let hostile = #"{"items":[{"full_name":"a/b","html_url":"https://evil.example/phish","url":"https://evil.example/x","description":"d"}]}"#
        #expect(Feeds.githubRepos(data(hostile)).map(\.url) == ["https://github.com/a/b"])
    }

    @Test(arguments: [
        #"{"items":[{"full_name":"no-slash"}]}"#, #"{"items":[{"full_name":"a/b/c"}]}"#, #"{"items":[{"full_name":"a b/c"}]}"#,
        #"{"items":[{"full_name":"a/b?x=1"}]}"#, #"{"items":[{"full_name":"../b"}]}"#, #"{"items":[{"full_name":"a/b#c"}]}"#,
        #"{"items":[{"full_name":"a/b@evil.example"}]}"#, #"{"items":[{"full_name":"a\\b/c"}]}"#, #"{"items":[{"full_name":5}]}"#,
        #"{"items":[{"full_name":"a/b","fork":true}]}"#, #"{"items":[{"full_name":"a/b","archived":true}]}"#, #"{"items":[{"full_name":"a/b","private":true}]}"#,
        #"{"items":"x"}"#, #"{"items":[1,null,"s",[]]}"#, #"[]"#, #"{}"#, "not json", "",
    ])
    func anEntryThatIsNotAPublicRepositoryIsDropped(json: String) {
        #expect(Feeds.githubRepos(data(json)).isEmpty, "\(json)")
    }

    @Test func hostileTextInADescriptionIsPlainAndShort() {
        let json = #"{"items":[{"full_name":"a/b","description":"<script>alert(1)</script>[x](javascript:alert(2)) \#(String(repeating: "y", count: 900))","topics":["<b>t</b>","‮x"],"stargazers_count":-5}]}"#
        let items = Feeds.githubRepos(data(json))
        holds(items)
        #expect(items.count == 1 && items[0].snippet.count <= 300 && items[0].popularity == 0)
    }

    @Test func atMostAHundredAreRead() {
        let many = (0..<150).map { #"{"full_name":"o/r\#($0)"}"# }.joined(separator: ",")
        #expect(Feeds.githubRepos(data("{\"items\":[\(many)]}")).count == 100)
    }
}

@Suite struct InternshipParserTests {
    @Test func simplifyKeepsActiveVisibleListingsWithAHttpsLink() {
        let items = Feeds.simplify(data(simplifyJSON))
        holds(items)
        #expect(items.map(\.company) == ["Western Digital", "Open Co"])  // inactive, hidden, http and untitled ones are gone
        let wd = items[0]
        #expect(wd.title == "Western Digital — 2026 Summer Intern - Data Engineering" && wd.kind == .internship && wd.source == "SimplifyJobs")
        #expect(wd.url == "https://jobs.smartrecruiters.com/WesternDigital/744000110544134?utm_source=Simplify&ref=Simplify")
        #expect(wd.id == "https://jobs.smartrecruiters.com/WesternDigital/744000110544134")  // tracking is not part of the key
        #expect(wd.published == Date(timeIntervalSince1970: 1_791_744_178))
        #expect(wd.location == ["San Jose, CA", "Remote in USA"] && wd.remote == true)
        #expect(wd.sponsorship == "Does Not Offer Sponsorship" && wd.tags == ["AI/ML/Data", "Summer 2027"])
        #expect(wd.eligibility == "Degrees: Bachelor's, Master's" && wd.deadline == nil && wd.deadlineNote == "none stated")
    }

    @Test func otherSponsorshipMeansUnknownAndNoLocationsMeansNoRemoteAnswer() {
        let open = Feeds.simplify(data(simplifyJSON))[1]
        #expect(open.sponsorship == "Offers Sponsorship" && open.remote == nil && open.location.isEmpty && open.eligibility == nil)
        let other = Feeds.simplify(data(#"[{"company_name":"C","title":"I","active":true,"url":"https://c.example/i","sponsorship":"Other"}]"#))
        #expect(other.first?.sponsorship == nil)
    }

    @Test func aListingWithoutFlagsCountsAsActive() {
        #expect(Feeds.simplify(data(#"[{"company_name":"C","title":"I","url":"https://c.example/i"}]"#)).count == 1)
        #expect(Feeds.simplify(data(#"[{"company_name":"C","title":"I","url":"https://c.example/i","active":false}]"#)).isEmpty)
    }

    @Test func aHugeListIsCapped() {
        let one = #"{"company_name":"C","title":"I","active":true,"is_visible":true,"url":"https://c.example/i/N"}"#
        let json = "[" + (0..<2_500).map { one.replacingOccurrences(of: "N", with: "\($0)") }.joined(separator: ",") + "]"
        #expect(Feeds.simplify(data(json)).count == 2_000)
    }

    @Test func greenhouseKeepsOnlyEarlyCareerRolesAndSplitsTheirPlaces() throws {
        let items = Feeds.greenhouse(data(greenhouseJSON), company: "anthropic")
        holds(items)
        let item = try #require(items.first)
        #expect(items.count == 1)  // the accounting job, "Internal Tools" and the javascript: link are gone
        #expect(item.title == "Anthropic — Research Engineer Intern, Summer 2027" && item.company == "Anthropic" && item.source == "Greenhouse")
        #expect(item.location == ["New York City, NY", "San Francisco, CA"])  // split on ; and |, the repeat dropped
        #expect(item.remote == true)  // "Location Type: Remote"
        #expect(item.deadline == at("2026-12-02T04:59:00Z") && item.deadlineNote == nil)
        #expect(item.published == at("2026-10-10T18:53:38Z"))
        #expect(item.url == "https://job-boards.greenhouse.io/anthropic/jobs/5391376008" && item.trust == 0.9)
    }

    @Test func greenhouseUsesTheGivenCompanyWhenTheJobHasNone() {
        let json = #"{"jobs":[{"absolute_url":"https://boards.greenhouse.io/acme/jobs/1","title":"Software Engineer Intern","location":{"name":"Remote"}}]}"#
        let item = Feeds.greenhouse(data(json), company: "Acme").first
        #expect(item?.title == "Acme — Software Engineer Intern" && item?.company == "Acme" && item?.remote == true)
        #expect(Feeds.greenhouse(data(json)).first?.title == "Software Engineer Intern")
    }

    @Test func leverReadsTheCommitmentAsFreeText() throws {
        let items = Feeds.lever(data(leverJSON), company: "Example")
        holds(items)
        #expect(items.count == 2)  // "Full-time" senior role is not early career
        let ml = items[0]
        #expect(ml.title == "Example — Machine Learning Engineer" && ml.kind == .internship && ml.source == "Lever")  // commitment "Intern"
        #expect(ml.location == ["Palo Alto, CA", "Remote"] && ml.remote == nil)  // hybrid says neither
        #expect(ml.snippet == "Join the ML team for the summer. You will train models.")
        #expect(ml.published == Date(timeIntervalSince1970: 1_791_744_178))  // milliseconds in, seconds out
        #expect(ml.tags == ["Intern", "Machine Learning"] && ml.url == "https://jobs.lever.co/example/0f1f7a26-1111-2222-3333-444444444444")
        let second = items[1]
        #expect(second.url == "https://jobs.lever.co/example/c/apply" && second.remote == true)  // hostedUrl is http: the apply link instead
    }

    @Test func ashbyDropsUnlistedJobsAndReadsTheEmploymentType() {
        let items = Feeds.ashby(data(ashbyJSON), company: "OpenAI")
        holds(items)
        #expect(items.map(\.title) == ["OpenAI — Research Intern", "OpenAI — Data Science Placement"])
        let intern = items[0]
        #expect(intern.remote == true && intern.location == ["London", "Remote - UK"] && intern.snippet == "Work on research.")
        #expect(intern.published == at("2026-10-01T08:00:00Z") && intern.tags == ["Alignment", "Research"])
        #expect(items[1].remote == false && items[1].location == ["Paris"])
    }

    @Test func aBoardWithoutJobsIsEmptyNotAnError() {
        #expect(Feeds.greenhouse(data(#"{"jobs":[],"meta":{"total":0}}"#)).isEmpty)
        #expect(Feeds.ashby(data(#"{"jobs":[]}"#)).isEmpty && Feeds.lever(data("[]")).isEmpty)
    }

    @Test(arguments: [("Software Engineering Intern", true), ("Summer Internship 2027", true), ("Co-op, Hardware", true), ("Coop Engineer", true),
                      ("Working Student (Werkstudent)", true), ("New Grad Software Engineer", true), ("Graduate Program, Analyst", true),
                      ("Early Career Researcher", true), ("Student Researcher", true), ("Internal Tools Engineer", false),
                      ("Senior Staff Engineer", false), ("International Sales Lead", false), ("Postgraduate Fellow Manager", false)])
    func earlyCareerTitles(_ title: String, _ expected: Bool) {
        #expect(Feeds.earlyCareer(title) == expected, "\(title)")
    }
}

// MARK: contests

@Suite struct ContestParserTests {
    @Test func ctftimeEventsLinkToCTFtimeAndStartAtTheirStart() throws {
        let items = Feeds.ctftime(data(ctfJSON))
        holds(items)
        #expect(items.map(\.id) == ["ctftime:3451", "ctftime:3454"])  // the one without a ctftime_url is dropped
        let onsite = items[0], online = items[1]
        #expect(onsite.kind == .contest && onsite.source == "CTFtime" && onsite.url == "https://ctftime.org/event/3451/")
        #expect(onsite.deadline == at("2026-09-25T04:00:00Z") && onsite.deadlineNote == "event start")
        #expect(onsite.remote == false && onsite.location == ["PSG College of Technology, Coimbatore, Tamil Nadu"] && onsite.eligibility == "Open")
        #expect(onsite.tags == ["CTF", "Jeopardy"] && onsite.popularity == 0)
        #expect(online.remote == true && online.location == ["online"] && online.popularity == 23.5 && online.eligibility == "Prequalified")
        #expect(online.title == "Null Origin CTF 2026: Grand finale")
        #expect(online.snippet == "Null Origin CTF 2026 — Grand Finale Null Origin is an international online Capture The Flag competition. • Duration: 12 Hours • Mode: Online")
    }

    @Test func codeforcesKeepsOnlyContestsThatHaveNotStarted() {
        let items = Feeds.codeforces(data(codeforcesJSON))
        holds(items)
        #expect(items.map(\.id) == ["codeforces:2278", "codeforces:2272", "codeforces:2277"])
        let first = items[0]
        #expect(first.url == "https://codeforces.com/contests/2278" && first.kind == .contest && first.source == "Codeforces")
        #expect(first.deadline == Date(timeIntervalSince1970: 1_793_457_300) && first.deadlineNote == "event start")
        #expect(first.snippet == "ICPC contest, 2 h 15 min" && items[1].snippet == "CF contest, 2 h")
        #expect(first.remote == true && first.location == ["online"])
    }

    @Test func aFailedCodeforcesCallGivesNothing() {
        #expect(Feeds.codeforces(data(#"{"status":"FAILED","comment":"contest.list: Call limit exceeded"}"#)).isEmpty)
        #expect(Feeds.codeforces(data(#"{"status":"OK","result":"x"}"#)).isEmpty)
    }
}

// MARK: the programme calendar and the apply link

@Suite struct ProgrammesTests {
    @Test func theCalendarHasTheSevenConfirmedOfficialPages() {
        let all = Programmes.all
        holds(all)
        #expect(all.count == 7 && Set(all.map(\.id)).count == 7)
        #expect(Set(all.map(\.host)) == ["summerofcode.withgoogle.com", "outreachy.org", "daad.de", "mitacs.ca", "careers.cern", "ghw.mlh.com", "fellowship.mlh.com"])
        #expect(all.filter { $0.kind == .hackathon }.map(\.host) == ["ghw.mlh.com"] && all.filter { $0.kind == .program }.count == 6)
    }

    @Test func everyProgrammeSaysCheckTheOfficialPageAndWhenItWasChecked() {
        for p in Programmes.all {
            #expect(p.deadline == nil && p.deadlineNote == "check the official page")
            #expect(p.snippet.hasSuffix(" Last checked 2026-10-20."), "\(p.title)")
            #expect(p.eligibility?.isEmpty == false && p.location.count == 1 && p.trust == 1 && p.remote != nil)
            #expect(p.published == nil)  // programmes do not age
        }
        #expect(Programmes.verified == at("2026-10-20T00:00:00Z"))
    }
}

@Suite struct ApplyWarningTests {
    @Test(arguments: [
        "https://boards.greenhouse.io/acme/jobs/1", "https://job-boards.greenhouse.io/acme/jobs/1", "https://jobs.lever.co/acme/1",
        "https://jobs.ashbyhq.com/acme/1", "https://apply.workable.com/acme/j/1", "https://jobs.smartrecruiters.com/Acme/1",
        "https://acme.wd5.myworkdayjobs.com/en-US/External/job/1", "https://careers-acme.icims.com/jobs/1", "https://jobs.jobvite.com/acme/job/1",
    ])
    func aKnownJobBoardNeedsNoWarning(_ url: String) {
        #expect(Feeds.applyWarning(for: url, company: "Acme") == nil)
        #expect(Feeds.applyWarning(for: url, company: "") == nil)
    }

    @Test(arguments: [
        ("https://careers.google.com/jobs/1", "Google LLC"), ("https://www.metacareers.com/jobs/1", "Meta"), ("https://jobs.apple.com/x", "Apple Inc."),
        ("https://amazon.jobs/x", "Amazon"), ("https://www.bbc.co.uk/careers/1", "BBC"), ("https://jpmorgan.com/jobs/1", "JPMorgan Chase & Co."),
        ("https://www.3m.com/jobs", "3M"),
    ])
    func theEmployersOwnDomainNeedsNoWarning(_ url: String, _ company: String) {
        #expect(Feeds.applyWarning(for: url, company: company) == nil, "\(url) for \(company)")
    }

    @Test(arguments: [
        ("https://google-careers-apply.xyz/job", "Google"), ("https://greenhouse.io.evil.example/job", "Acme"), ("https://evilgreenhouse.io/job", "Acme"),
        ("https://lever.co.example.net/x", "Acme"), ("https://googlecareers.com.apply-now.example/x", "Google"), ("https://bit.ly/3abc", "Acme"),
    ])
    func aLookalikeOrUnrelatedDomainGetsAWarning(_ url: String, _ company: String) throws {
        let warning = try #require(Feeds.applyWarning(for: url, company: company))
        #expect(warning.contains(URLComponents(string: url)!.host!) && warning.contains("Check the employer"))
    }

    @Test func theWarningNamesTheEmployerWhenKnownAndNotWhenNot() {
        #expect(Feeds.applyWarning(for: "https://apply.example.xyz/j", company: "Acme Inc")?.contains("Acme Inc's own site or a known job board") == true)
        #expect(Feeds.applyWarning(for: "https://apply.example.xyz/j", company: "")?.contains("not a known job board") == true)
    }

    @Test func aLinkThatIsNotHttpsIsNeverTrusted() {
        #expect(Feeds.applyWarning(for: "http://boards.greenhouse.io/acme/jobs/1", company: "Acme")?.contains("not a secure") == true)
        #expect(Feeds.applyWarning(for: "javascript:alert(1)", company: "Acme") != nil)
        #expect(Feeds.applyWarning(for: "", company: "Acme") != nil)
    }
}

// MARK: hostile and malformed input, for every parser

@Suite struct HostileInputTests {
    private static let json: [(String, (Data) -> [RadarItem])] = [
        ("huggingFace", Feeds.huggingFacePapers), ("hackerNews", Feeds.hackerNews), ("simplify", Feeds.simplify),
        ("greenhouse", { Feeds.greenhouse($0) }), ("lever", { Feeds.lever($0) }), ("ashby", { Feeds.ashby($0) }),
        ("ctftime", Feeds.ctftime), ("codeforces", Feeds.codeforces),
    ]
    private static let xml: [(String, (Data) -> [RadarItem])] = [("arxiv", Feeds.arxiv), ("news", { Feeds.news($0) })]

    private static let junk: [Data] = [
        Data(), data("null"), data("[]"), data("{}"), data("123"), data("\"str\""), data("true"), data("[1,2,3]"), data("[[[[[["), data("{\"a\":"),
        data("{\"jobs\":5}"), data("{\"jobs\":[1,2,\"x\",null]}"), data("{\"result\":\"x\",\"status\":\"OK\"}"), data("[{\"paper\":[]}]"),
        Data([0x00, 0x01, 0xFF, 0xFE, 0x80]), Data((0..<5_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) }),
        data(String(repeating: "[", count: 100_000)), data(String(repeating: "{\"a\":", count: 50_000)),
        data("{\"jobs\":[{\"title\":\"Intern\",\"absolute_url\":\"https://a.example/x\",\"id\":1e999}]}").prefix(40) as Data,
        data("<html><body><h1>404 Not Found</h1></body></html>"), data("<?xml version=\"1.0\"?><feed>"), data("<feed><entry><title>x"),
    ]

    @Test func junkNeverCrashesAndGivesNothingUsable() {
        for (name, parse) in Self.json + Self.xml {
            for input in Self.junk {
                let items = parse(input)
                holds(items)
                #expect(items.isEmpty, "\(name) on \(input.count) bytes")
            }
        }
    }

    /// An unterminated `{"a":{"a":...` 50 000 deep overflowed a worker thread's stack inside JSONSerialization (found by this suite
    /// on 2026-10-20); the parsers refuse more than 32 levels before JSONSerialization sees the bytes.
    @Test func deepNestingIsRefusedBeforeItCanOverflowTheStack() async {
        let open = String(repeating: "{\"a\":", count: 400)
        await Task.detached {  // a worker thread, as the fetcher will run them
            for (_, parse) in Self.json { #expect(parse(Data(open.utf8)).isEmpty) }
        }.value
        #expect(Feeds.shallow(data("[[[[]]]]")) && Feeds.shallow(data(String(repeating: "[", count: 32) + String(repeating: "]", count: 32))))
        #expect(!Feeds.shallow(data(String(repeating: "[", count: 33) + String(repeating: "]", count: 33))))
        #expect(!Feeds.shallow(data(String(repeating: "{\"a\":", count: 40) + "1" + String(repeating: "}", count: 40))))
        // brackets inside strings (with escaped quotes) do not count, and closers do not go below zero
        #expect(Feeds.shallow(data(#"{"a":"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[","b":"\"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[["}"#)))
        #expect(Feeds.shallow(data("]]]]]]]]]]" + String(repeating: "[", count: 30))))
        for fixture in [hfJSON, simplifyJSON, greenhouseJSON, leverJSON, ashbyJSON, ctfJSON, codeforcesJSON, hnDropbox] { #expect(Feeds.shallow(data(fixture))) }
    }

    @Test func anEntityBombIsRejectedBeforeParsing() {
        var bomb = "<?xml version=\"1.0\"?>\n<!DOCTYPE lolz [\n <!ENTITY lol \"lol\">\n"
        for n in 1...9 { bomb += " <!ENTITY lol\(n) \"" + String(repeating: "&lol\(n == 1 ? "" : "\(n - 1)");", count: 10) + "\">\n" }
        bomb += "]>\n<rss><channel><item><title>&lol9;</title><link>https://example.com/a</link></item></channel></rss>"
        let atom = bomb.replacingOccurrences(of: "<rss><channel><item>", with: "<feed><entry><id>oai:arXiv.org:2610.00001v1</id>")
            .replacingOccurrences(of: "</item></channel></rss>", with: "</entry></feed>")
        #expect(Feeds.news(data(bomb)).isEmpty && Feeds.arxiv(data(atom)).isEmpty)
    }

    @Test func anExternalEntityIsRejectedToo() {
        let xxe = """
        <?xml version="1.0"?><!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <rss><channel><item><title>&xxe;</title><link>https://example.com/a</link></item></channel></rss>
        """
        #expect(Feeds.news(data(xxe)).isEmpty)
        // A lower-case doctype is not XML; whatever the parser does with it, nothing but clean items may come out.
        holds(Feeds.news(data("<!doctype html><rss><channel><item><title>x</title><link>https://example.com/a</link></item></channel></rss>")))
    }

    @Test func utf16AndNulBytesAreRejectedSoNoDoctypeCanHideInThem() {
        let doc = "<?xml version=\"1.0\"?><rss><channel><item><title>x</title><link>https://example.com/a</link></item></channel></rss>"
        #expect(Feeds.news(doc.data(using: .utf16)!).isEmpty && Feeds.news(doc.data(using: .utf16LittleEndian)!).isEmpty)
        #expect(Feeds.news(data("<rss>\u{0}<channel></channel></rss>")).isEmpty)
        #expect(Feeds.news(data(doc)).count == 1)  // the same document in UTF-8 is fine
    }

    @Test func deeplyNestedXMLEndsWithoutCrashing() {
        let deep = "<rss><channel>" + String(repeating: "<a>", count: 100_000) + "</channel></rss>"
        #expect(Feeds.news(data(deep)).isEmpty)
        let inside = "<rss><channel><item><title>kept</title><link>https://example.com/a</link>" + String(repeating: "<b>", count: 100_000)
        _ = Feeds.news(data(inside))  // whatever it returns, it returns
    }

    @Test func aTruncatedFeedKeepsTheEntriesThatWereComplete() {
        let cut = String(arxivFeed[..<arxivFeed.range(of: "<id>oai:arXiv.org:2610.22474v1</id>")!.lowerBound])
        #expect(Feeds.arxiv(data(cut)).map(\.id) == ["arxiv:2610.22444"])
    }

    @Test func aFeedBiggerThanTheCapIsReadAsFarAsItGoes() {
        let item = "<item><title>t</title><link>https://example.com/a</link><description>" + String(repeating: "x", count: 1_000_000) + "</description></item>"
        let xml = "<rss><channel>" + String(repeating: item, count: 12) + "</channel></rss>"  // ~12 MB, over the 8 MB cap
        let items = Feeds.news(data(xml))
        #expect(items.count >= 7 && items.count <= 8)
    }

    @Test func textFieldsLoseBidiAndZeroWidthCharacters() {
        let xml = "<rss><channel><item><title>Hel\u{202E}lo\u{200B} Wor\u{FEFF}ld</title><link>https://example.com/a</link></item></channel></rss>"
        #expect(Feeds.news(data(xml)).first?.title == "Hello World")
        #expect(Plain.text("A\u{0007}B\u{0000}C\u{202E}D\u{200B}E\u{2066}F\u{E000}G", max: 50) == "ABCDEFG")
    }
}

// MARK: the item and the text helpers

@Suite struct RadarItemTests {
    private func make(title: String = "T", url: String = "https://example.com/a", kind: RadarItem.Kind = .news, deadline: Date? = nil,
                      deadlineNote: String? = nil, trust: Double = 0.5) -> RadarItem? {
        RadarItem(kind: kind, title: title, url: url, source: "S", deadline: deadline, deadlineNote: deadlineNote, trust: trust)
    }

    @Test func noTitleOrNoHttpsUrlMeansNoItem() {
        #expect(make() != nil)
        #expect(make(title: "") == nil && make(title: "  \n ") == nil && make(title: "<b></b>") == nil)
        #expect(make(url: "http://example.com") == nil && make(url: "") == nil && make(url: "example.com") == nil)
    }

    @Test func anOpportunityAlwaysSaysSomethingAboutItsDeadline() {
        for kind in RadarItem.Kind.allCases {
            let item = make(kind: kind)!
            #expect(item.deadlineNote == (item.isOpportunity ? "none stated" : nil), "\(kind)")
        }
        #expect(make(kind: .internship, deadline: at("2026-12-01T00:00:00Z"))?.deadlineNote == nil)
        #expect(make(kind: .internship, deadlineNote: "rolling")?.deadlineNote == "rolling")
        #expect(RadarItem.Kind.allCases.map(\.rawValue) == ["paper", "news", "announcement", "repo", "internship", "program", "contest", "hackathon"])
        #expect(RadarItem.Kind.allCases.filter { !make(kind: $0)!.isOpportunity } == [.paper, .news, .announcement, .repo])
    }

    @Test func trustPopularityAndDatesAreMadeSane() {
        #expect(make(trust: 7)?.trust == 1 && make(trust: -1)?.trust == 0 && make(trust: .nan)?.trust == 0 && make(trust: .infinity)?.trust == 0)
        let odd = RadarItem(kind: .paper, title: "T", url: "https://example.com/a", source: "S", published: Date(timeIntervalSince1970: 5),
                            deadline: Date(timeIntervalSince1970: 9_999_999_999_999), popularity: -4, trust: 1)
        #expect(odd?.published == nil && odd?.deadline == nil && odd?.popularity == 0)
        #expect(RadarItem(kind: .paper, title: "T", url: "https://example.com/a", source: "S", popularity: .nan, trust: 1)?.popularity == nil)
    }

    @Test func listsAreCleanedDedupedAndCapped() {
        let tags = (0..<30).map { "tag \($0)" } + ["TAG 1", "  ", "<b>bold</b>"]
        let item = RadarItem(kind: .paper, title: "T", url: "https://example.com/a", source: "", tags: tags, location: Array(repeating: "Here", count: 20), trust: 1)
        #expect(item?.tags.count == 8 && item?.tags.first == "tag 0" && item?.location == ["Here"])
        #expect(item?.source == "example.com")
    }

    @Test func theHostIsDerivedWithoutWww() {
        #expect(make(url: "https://WWW.Example.com:8443/a?b=c#d")?.host == "example.com")
        #expect(make(url: "https://news.ycombinator.com/item?id=1")?.host == "news.ycombinator.com")
    }

    @Test func itRoundTripsThroughJSON() throws {
        let item = try #require(RadarItem(id: "arxiv:2610.22444", kind: .internship, title: "Co — Intern", url: "https://example.com/a", source: "S",
                                          snippet: "s", published: at("2026-10-19T04:00:00Z"), deadline: at("2026-12-01T00:00:00Z"), deadlineNote: "n",
                                          popularity: 3, tags: ["a"], location: ["b"], remote: false, eligibility: "e", sponsorship: "sp", company: "Co", trust: 0.6))
        let back = try JSONDecoder().decode(RadarItem.self, from: JSONEncoder().encode(item))
        #expect(back == item)
    }
}

@Suite struct PlainTextTests {
    @Test func tagsEntitiesAndWhitespaceBecomeOneCleanLine() {
        #expect(Plain.text("  <p>Tom &amp; Jerry&nbsp;&#169; &#x41;\n\n  <br/>ok</p> ", max: 100) == "Tom & Jerry © A ok")
        #expect(Plain.text("H<sub>2</sub>O is <b>very</b> <i>wet</i>. <STRONG>Loud</STRONG><br>Next", max: 100) == "H2O is very wet. Loud Next")
        #expect(Plain.text("x < y and z > w", max: 100) == "x < y and z > w")
        #expect(Plain.text("ok<script>alert(1)", max: 100) == "ok")
        #expect(Plain.text("a<style>p{x}</style>b <!-- hidden --> c", max: 100) == "a b c")
        #expect(Plain.text("&lt;script&gt;x&lt;/script&gt;Hi", max: 100) == "Hi")
        #expect(Plain.text("&bogus; &#xFFFFFFFF; &#xD800; & done", max: 100) == "&bogus; &#xFFFFFFFF; &#xD800; & done")
    }

    @Test func aCutEndsInAnEllipsisWithinTheLimit() {
        let t = Plain.text(String(repeating: "word ", count: 100), max: 20)
        #expect(t.count <= 20 && t.hasSuffix("…"))
        #expect(Plain.text("short", max: 20) == "short")
        #expect(Plain.text("Robot 🤖 café", max: 20) == "Robot 🤖 café")
    }

    @Test func httpsUrlsAreStrict() {
        #expect(Plain.https(" https://example.com/a b ") == nil)
        #expect(Plain.https("HTTPS://Example.com/Path") == "https://Example.com/Path")
        for bad in ["javascript:alert(1)", "http://example.com", "//example.com", "https://example", "https://u:p@example.com/", "https:///path",
                    "https://exa\u{7}mple.com/", "https://example.com/\u{0}", "file:///etc/passwd", "https://" + String(repeating: "a", count: 5_000) + ".com"] {
            #expect(Plain.https(bad) == nil, "\(bad.prefix(40))")
        }
    }

    @Test func theDedupeFormOfAUrl() {
        #expect(Plain.normalised("https://www.Example.com:443/a/b/?utm_source=x&b=2&a=1&fbclid=z#frag") == "https://example.com/a/b?a=1&b=2")
        #expect(Plain.normalised("https://example.com/") == "https://example.com")
        #expect(Plain.normalised("https://example.com:8443/x") == "https://example.com:8443/x")
    }

    @Test func arxivAndDoiLinksGetTheirOwnIds() {
        #expect(Plain.key("https://arxiv.org/abs/2610.22444v3") == "arxiv:2610.22444")
        #expect(Plain.key("https://arxiv.org/pdf/2610.22444.pdf") == "arxiv:2610.22444")
        #expect(Plain.key("https://export.arxiv.org/abs/hep-th/9901001v2") == "arxiv:hep-th/9901001")
        #expect(Plain.key("https://arxiv.org/abs/not-an-id") == "https://arxiv.org/abs/not-an-id")
        #expect(Plain.key("https://doi.org/10.1000/XYZ123") == "doi:10.1000/xyz123")
        #expect(Plain.key("https://example.com/a?utm_medium=x") == "https://example.com/a")
    }

    @Test func datesComeInIsoRfc822AndEpochForms() {
        let target = at("2026-10-19T04:00:34Z").timeIntervalSince1970
        #expect(abs(When.parse("2026-10-19T04:00:34.864776+00:00")!.timeIntervalSince1970 - target) < 1)
        #expect(abs(When.parse("2026-10-19T00:00:34-04:00")!.timeIntervalSince1970 - target) < 1)
        #expect(When.parse("2026-10-19T04:00:34Z")!.timeIntervalSince1970 == target)
        #expect(When.parse("Mon, 19 Oct 2026 14:20:00 -0400") == at("2026-10-19T18:20:00Z"))
        #expect(When.parse("Mon, 19 Oct 2026 14:20:00 GMT") == at("2026-10-19T14:20:00Z"))
        #expect(When.parse("2026-10-24") == at("2026-10-24T00:00:00Z"))
        #expect(When.parse("yesterday") == nil && When.parse("") == nil && When.parse(nil) == nil && When.parse(String(repeating: "9", count: 500)) == nil)
        #expect(When.epoch(1_791_744_178) == When.epoch(1_791_744_178_000) && When.epoch(-5) == nil && When.epoch(.infinity) == nil && When.epoch(nil) == nil)
    }
}
