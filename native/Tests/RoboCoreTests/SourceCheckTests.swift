// The source check: which addresses and offers Robo believes, warns about or never shows. Pure and offline, so every case is an address or
// a sentence. The legitimate hosts matter as much as the scams: a check that cries wolf teaches people to click through it.
import Foundation
import Testing
@testable import RoboCore

private func level(_ url: String, words: String = "") -> SourceCheck.Level { SourceCheck.assess(url: url, words: words).level }

private func offer(_ kind: RadarItem.Kind = .internship, title: String = "Software Engineer Intern", url: String = "https://careers.example.com/jobs/1",
                   company: String? = "Example", snippet: String = "", eligibility: String? = nil) -> RadarItem {
    RadarItem(kind: kind, title: title, url: url, source: "test", snippet: snippet, eligibility: eligibility, company: company, trust: 0.5)!
}

@Suite struct SourceCheckAddressTests {
    // MARK: sources that are fine

    @Test(arguments: [
        "https://arxiv.org/abs/2410.01234", "https://www.nature.com/articles/s41586-020-2649-2", "https://ocw.mit.edu/courses/6-006/",
        "https://www.mbzuai.ac.ae/study/", "https://www.nih.gov/news", "https://www.ox.ac.uk/admissions", "https://openreview.net/forum?id=abc",
        "https://ctftime.org/event/3340/", "https://doi.org/10.1038/nature14539",
    ])
    func aKnownPrimarySourceIsOfficial(url: String) {
        let v = SourceCheck.assess(url: url)
        #expect(v.level == .official && v.reasons.isEmpty && !v.notes.isEmpty, "\(url): \(v)")
    }

    /// Real hosts with the words that scams use in theirs (login, secure, support), and brand names inside other words.
    @Test(arguments: [
        "https://accounts.google.com/signin", "https://login.microsoftonline.com/common/oauth2", "https://support.apple.com/en-us/HT201", "https://appleid.apple.com/",
        "https://aws.amazon.com/jobs", "https://www.amazon.jobs/en/", "https://careers.google.com/jobs/", "https://www.google.co.uk/", "https://www.google.ae/", "https://www.amazon.de/",
        "https://www.paypal.com/signin", "https://secure.paypal.com/", "https://github.com/foo/bar", "https://google.github.io/styleguide/", "https://openai.github.io/x",
        "https://pineapple.com/", "https://www.applesauce.org/", "https://metadata.org/", "https://amazonia.org/", "https://zoomable.example.com/", "https://boards.greenhouse.io/openai/jobs/1",
        "https://acme.wd5.myworkdayjobs.com/en-US/careers/job/1", "https://jobs.lever.co/acme/abc", "https://lifeattiktok.com/search/1", "https://jobs.bytedance.com/en/position/1/detail",
        "https://news.ycombinator.com/item?id=1", "https://www.nytimes.com/2026/10/21/technology/ai.html", "https://huggingface.co/papers/2410.01234", "https://www.youtube.com/watch?v=abc",
        "https://docs.google.com/document/d/1abc/edit", "https://www.zoom-lens-shop.com/",
        // found on real data: a company's name before a job platform is how Workday, Taleo and Oracle boards work
        "https://nvidia.wd5.myworkdayjobs.com/NVIDIAExternalCareerSite/job/US-CA-Santa-Clara/Intern_JR1", "https://adobe.wd5.myworkdayjobs.com/external_experienced/job/San-Jose/x",
        "https://egug.fa.us2.oraclecloud.com/hcmUI/CandidateExperience/en/sites/CX/job/1", "https://textron.taleo.net/careersection/2/jobdetail.ftl",
        // and the brands' own other domains (popular on the web, none a scam)
        "https://google.org/", "https://google.dev/", "https://microsoft.net/", "https://openai.org/", "https://facebook.net/", "https://netflix.net/",
        "https://www.google-analytics.com/analytics.js", "https://s-microsoft.com/x", "https://samsung-news.com/", "https://tiktokv.com/", "https://hicloud.com/",
        // the user's own university and the services it runs on (found by the false-positive hunter: all were called scams)
        "https://moodle.mbzuai.ac.ae/course/view.php?id=12", "https://moodle.stanford.edu/course/view.php?id=2", "https://moodle.ox.ac.uk/", "https://moodle.university.edu/my/",
        "https://mbzuai-my.sharepoint.com/:b:/g/personal/student_mbzuai_ac_ae/abc", "https://mbzuai.zoom.us/j/123456", "https://nvidia.zoom.us/webinar/register/W1",
        "https://mbzuai.instructure.com/", "https://outlook.office365.com/mail/", "https://openai.azure.com/", "https://nvidia.okta.com/", "https://outlook.cloud.microsoft/mail",
        "https://www.google.com.co/", "https://www.google.cl/", "https://www.google.com.pe/", "https://google.us/", "https://microsoftazuread-sso.com/",
        "https://google-research.github.io/self-organising-systems/", "https://google-deepmind.github.io/some-project/", "https://nvidia-research.github.io/proj/",
        "https://www.iros2025.org/", "https://robocup2025.org/", "https://jobs.80000hours.org/", "https://samsun.edu.tr/", "https://ai.google.dev/gemini-api/docs",
        "https://ai-safety-notes.pages.dev/accountability-in-ai", "https://abc.notion.site/Secure-Computation-abc123", "https://my-project.vercel.app/verify-llm-outputs",
        "https://東京tech.com/", "https://təhsil.az/", "https://xn--n1aen.xn--p1ai/", "https://org@dev.azure.com/org/project/_git/repo", "https://user@github.com/owner/repo.git",
        "https://www.nus.edu.sg/", "https://www.kaust.edu.sa/en", "https://www.amazon.com.br/", "https://careers.cern/", "https://block.xyz/careers",
        // governments and universities under country endings that look cheap but are kept for them; names that only contain a brand's
        "https://unal.edu.co/", "https://dian.gov.co/", "https://cbl.gov.ly/", "https://metanet.ch/", "https://www.metacareers.com/", "https://web.archive.org/web/2024/https://arxiv.org/abs/1",
    ])
    func realHostsAreNotFlaggedAsScamOrDoubtful(url: String) {
        let v = SourceCheck.assess(url: url)
        #expect(v.level <= .ordinary, "\(url): \(v)")
    }

    @Test func aBlogOrAForumIsMarkedWrittenByAnyoneAndNothingWorse() {
        let medium = SourceCheck.assess(url: "https://medium.com/@someone/a-post")
        #expect(medium.level == .ordinary && medium.notes.contains { $0.contains("written by anyone") })
        #expect(SourceCheck.assess(url: "https://github.com/a/b").notes.contains { $0.contains("written by anyone") })
    }

    @Test func aJobBoardIsKnownButTheEmployerStillNeedsChecking() {
        let v = SourceCheck.assess(url: "https://boards.greenhouse.io/acme/jobs/1")
        #expect(v.level == .ordinary && v.notes.contains { $0.contains("job-board platform") && $0.contains("check the employer") })
    }

    // MARK: scams and doubtful addresses

    @Test(arguments: [
        "https://paypal.com.evil.xyz/login", "https://login.microsoft.com.account-check.net/", "https://www.google.com.signin-secure.top/", "https://secure-paypal.com/",
        "https://paypal-login.com/", "https://apple-support.net/", "https://microsoft-verify.xyz/", "https://amazon-account-update.com/", "https://login-microsoft.netlify.app/",
        "https://paypa1.com/", "https://g00gle.com/", "https://rnicrosoft.com/", "https://app1e.com/", "https://micr0soft-support.com/",
        "https://google.com@evil.example/", "https://paypal@evil.example/", "https://8.8.8.8/", "https://3232235777/", "https://0x7f.0.0.1/",
        "https://xn--pple-43d.com/", "https://\u{0430}pple.com/",
        // a known domain written in front of another one (found by the red team: only brand keys were looked for)
        "https://login.microsoftonline.com.evil-site.com/common/oauth2", "https://www.office.com.evil-site.com/", "https://claude.ai.evil-site.com/", "https://sharepoint.com.evil-site.com/",
        "https://arxiv.org.evil.net/abs/2401.00001", "https://mit.edu.evil.com/", "https://ox.ac.uk.evil.com/", "https://doi.org.evil-site.com/", "https://openreview.net.evil.com/",
        "https://kaust.edu.sa.evil.com/", "https://login.mit.edu.verify-login.org/", "https://mbzuai.ac.ae.evil-site.com/", "https://huggingface.co.evil-site.com/",
        // brand names with login words in other shapes, and typos with a digit
        "https://securepaypal.com/", "https://loginmicrosoft.com/", "https://verifyapple.com/", "https://microsoftonline-login.com/", "https://microsoft365-login.com/",
        "https://office-365-login.com/", "https://paypal-refund.com/", "https://mbzuai-student-portal.com/", "https://owa-mbzuai.com/", "https://microsoft-teams-meeting.com/join",
        "https://paypa1-secure.netlify.app/", "https://micros0ft.vercel.app/", "https://paypal-login.zoom.us/", "https://secure-login-paypal.teamtailor.com/",
        "https://login.microsoft.com.ga/", "https://paypal.com.tk/login", "https://wallet-binance.com/", "https://claude-login.com/", "https://arxiv-org.com/abs/2401.00001",
        "https://appleid-support.com/", "https://microsoft-account-security.com/", "https://paypal.com.co/signin", "https://amazon.com.co/gp/css",
        "https://wellsfargo-verify.com/", "https://emiratesnbd-secure.com/",
        // accents and dotless letters standing for plain ones, fullwidth and invisible characters
        "https://paypál.com/login", "https://gøøgle.com/", "https://gıthub.com/", "https://ıcloud.com/", "https://amazón.com/",
        "https://ｐａｙｐａｌ-ｌｏｇｉｎ.com/", "https://pay\u{200B}pal-login.com/", "https://login.paypal\u{3002}com\u{3002}evil\u{3002}xyz/",
        // addresses that are not what they look like
        "https://evil.com%2F.arxiv.org/", "https://arxiv.org\u{2215}abs\u{2215}2401.evil-site.com/", "smb://evil-site.com/share", "ftp://evil-site.com/payload.zip",
        "https://127.0.0.1.nip.io/login", "https://192-168-1-5.sslip.io/",
    ])
    func aClearScamShapeIsAScam(url: String) {
        let v = SourceCheck.assess(url: url)
        #expect(v.level == .scam && v.hidden && !v.reasons.isEmpty, "\(url): \(v)")
    }

    @Test(arguments: [
        "https://bit.ly/3abcde", "https://t.co/xyz", "https://tinyurl.com/job", "https://invoice.zip/x", "https://paypal.netlify.app/",
        "https://linkedln.com/in/someone", "https://google-careers.xyz/apply", "https://googlecareers.com/apply", "https://applejobs.com/",
        // the user's own network: not a scam, but not a website to send anyone to
        "https://192.168.0.1/login", "https://localhost:8000/x", "https://printer.local/admin", "https://[::1]/x", "https://intranet/", "https://foo.localhost/",
        // a known name on a cheap ending, the same label as a source it is not, and one letter off
        "https://paypal.tk/signin", "https://paypal.cc/signin", "https://mbzuai.cc/scholarship", "https://arxiv.com/abs/2401.00001",
        "https://paypall.com/", "https://gooogle.com/", "https://openrevlew.net/", "https://neurlps.cc/",
        // the red team's scam words with no brand at all, free hosting with a login page, an open redirect to another site
        "https://secure-login-verify.com/", "https://account-verification-portal.net/", "https://free-bitcoin-giveaway.com/", "https://hackathon-prize-claim.com/",
        "https://www.google.com/url?q=https://evil.example/login&sa=D", "https://l.facebook.com/l.php?u=https%3A%2F%2Fevil.example%2F", "https://www.nature.com/?url=https://evil.example",
        "https://mit.edu/out?url=https%3A%2F%2Fevil.example%2F",
        // the real address is the first one; a known name only sits in the path or the second hop is hidden in it
        "https://evil-site.com/https://arxiv.org/abs/2401.00001", "https://evil-site.com/arxiv.org/login", "https://www.google.com/amp/s/evil-site.com/login",
        "https://example.org/https://evil-site.com",
        // a school or government in looks only, under an ending that hands out any name
        "https://evil.edu.tk/login", "https://evil.ac.ml/", "https://evil.gov.ga/pay",
        // look-alikes of the sources Robo itself vouches for, of the reader's own school, of Meta's job pages
        "https://arxiv-submit.org/", "https://codeforces-rating-boost.com/", "https://mbzuai-ac-ae.com/login", "https://mbzuai.ae/", "https://metacareers-apply.com/",
        "https://meta-careers.org/",
    ])
    func aWeakerSignalIsDoubtfulNotHidden(url: String) {
        let v = SourceCheck.assess(url: url)
        #expect(v.level == .doubtful && v.warns && !v.hidden && !v.reasons.isEmpty, "\(url): \(v)")
    }

    /// Study groups and student clubs live on Telegram, WhatsApp and Google Forms: for a plain link or an event that is a hint; for a job
    /// (an employer has its own site) it is a warning.
    @Test func aChatOrFormLinkIsAHintForALinkAndAnEventButAWarningForAJob() {
        for url in ["https://t.me/hiring_hr", "https://wa.me/971500000000", "https://chat.whatsapp.com/abc", "https://forms.gle/xyz",
                    "https://docs.google.com/forms/d/e/1FAIpQ/viewform", "https://tally.so/r/abc", "https://discord.gg/abc"] {
            let link = SourceCheck.assess(url: url)
            #expect(link.level == .ordinary && link.reasons.contains { $0.contains("chat or form site") }, "\(url): \(link)")
            #expect(SourceCheck.assess(offer(.hackathon, title: "Student club hackathon", url: url, company: nil)).level == .ordinary, "event \(url)")
            #expect(SourceCheck.assess(offer(url: url, company: "Acme")).level == .doubtful, "job \(url)")
        }
        // a student club's page on free hosting is a hint for an event too, and a warning only for a job
        let hack = offer(.hackathon, title: "Student club hackathon", url: "https://nyuad-hackathon.netlify.app/", company: nil)
        #expect(SourceCheck.assess(hack).level == .ordinary)
        #expect(SourceCheck.assess(offer(url: "https://nyuad-hackathon.netlify.app/", company: "Acme")).level == .doubtful)
    }

    @Test func oneMildSignalOnItsOwnIsOnlyAReasonNotAWarning() {
        for url in ["http://example.com/page", "https://blog.example.xyz/post", "https://example.com:8443/x", "https://www.zoom-lens-shop.com/"] {
            let v = SourceCheck.assess(url: url)
            #expect(v.level == .ordinary, "\(url): \(v)")
        }
        #expect(!SourceCheck.assess(url: "http://example.com/page").reasons.isEmpty)
    }

    /// Most live phishing sits on free hosting under a random name: the hosting, the cluttered name and a login-style path add up, where
    /// an ordinary project page on the same host does not.
    @Test func aRandomPageOnFreeHostingWarnsButAProjectPageDoesNot() {
        for url in ["https://sp20ct10-davrelo-biz-kunima.pages.dev/send_appeal_request", "https://nus.nbt.mybluehost.me/website_9f694753/cc/login.php",
                    "https://mavzelo-mpt-firqanu-r6x9pe27.pages.dev/", "https://secure-update.web.app/account/verify"] {
            let v = SourceCheck.assess(url: url)
            #expect(v.level == .doubtful && v.reasons.contains { $0.contains("hosting service") || $0.contains("login") }, "\(url): \(v)")
        }
        for url in ["https://my-project.netlify.app/docs", "https://someone.github.io/blog/", "https://example.pages.dev/", "https://my-site.vercel.app/"] {
            #expect(SourceCheck.assess(url: url).level == .ordinary, "\(url)")
        }
        // an opportunity on free hosting is doubtful by itself: a real employer or organiser has its own site
        #expect(SourceCheck.assess(offer(url: "https://apply.acme-offers.pages.dev/9", company: "Acme")).level == .doubtful)
    }

    @Test func manyMildSignalsTogetherWarn() {
        let v = SourceCheck.assess(url: "https://very-cheap-fast-offers-2026.example.xyz:8443/a?url=https://other.example/")
        #expect(v.level == .doubtful && v.reasons.count >= 2, "\(v)")
    }

    @Test func anAddressThatIsNotAWebAddressIsNotTrusted() {
        #expect(level("not a url") == .doubtful)
        #expect(level("") == .doubtful)
        #expect(level("https:///nohost") == .doubtful)
    }

    // MARK: the words of a link

    @Test func aLinkWhoseWordsAreAnotherAddressIsAScam() {
        #expect(level("https://evil.example.xyz/login", words: "paypal.com") == .scam)
        #expect(level("https://evil.example.xyz/x", words: "https://www.microsoft.com") == .scam)
        #expect(level("https://evil.example.xyz/x", words: "paypal[.]com") == .scam)
        #expect(level("https://evil.example.xyz/x", words: "paypal\u{3002}com") == .scam)
        #expect(level("https://evil.example.xyz/x", words: "paypal . com") == .scam)
        #expect(level("https://evil.com/", words: "doi.org/10.1000/1") == .scam)  // a DOI resolver leads to a publisher, not to any address
        #expect(level("https://paypal.zoom.us/verify") == .doubtful)  // a name people steal money in, on someone's tenant of a service
        #expect(SourceCheck.assess(url: "https://evil.example/x", words: "paypal.com").reasons.first?.contains("paypal.com") == true)
    }

    /// A sentence that names a brand beside a sign-in word, on an address that is not the brand's, is doubtful, not a scam: it may be a
    /// post about that brand. (Only link text that is nothing but an address is compared hard.)
    @Test func aBrandAndASignInInTheWordsOfAForeignLinkIsDoubtful() {
        for words in ["Sign in to your Microsoft account", "Verify your MBZUAI Moodle account", "Sign in at https://www.microsoft.com", "Log in to PayPal"] {
            #expect(level("https://evil.example.xyz/x", words: words) == .doubtful, "\(words)")
        }
        #expect(level("https://login.microsoftonline.com/common/oauth2", words: "Sign in to your Microsoft account") <= .ordinary)
        #expect(level("https://moodle.mbzuai.ac.ae/", words: "Log in to MBZUAI Moodle") <= .official)
        #expect(level("https://news.example.org/story", words: "Microsoft Teams docs") == .ordinary)  // no sign-in word
    }

    /// Two different addresses that the same people own (found by the false-positive hunter) are not a scam: it is the scam only when the
    /// words name a site Robo knows and the link goes somewhere it does not.
    @Test func linkWordsThatNameAnotherButRelatedSiteAreAtMostAWarning() {
        for (words, url) in [("arxiv.org/abs/1706.03762", "https://ar5iv.org/abs/1706.03762"), ("bbc.co.uk", "https://www.bbc.com/news/technology-1"), ("bbc.com", "https://www.bbc.co.uk/news/1"),
                             ("pypi.org/project/numpy", "https://pypi.python.org/pypi/numpy"), ("vscode.dev", "https://code.visualstudio.com/"),
                             ("cs231n.stanford.edu", "https://cs231n.github.io/"), ("ctf.example.com", "https://ctftime.org/event/1"), ("Booking.com", "https://example.com/post")] {
            #expect(level(url, words: words) <= .doubtful, "\(words) -> \(url)")
        }
        #expect(level("https://www.bbc.com/news/technology-1", words: "bbc.co.uk") == .ordinary)  // the same name under two ordinary endings is one owner
        #expect(level("https://www.google.de/", words: "google.com") == .ordinary)
        #expect(level("https://ctftime.org/event/1", words: "ctf.example.com") == .doubtful)  // a primary address under another name: a warning, not a scam
        #expect(level("https://evil.example.xyz/x", words: "arxiv.org") == .scam)  // a known name on a stranger's address
        #expect(level("https://www.paypal.tk/signin", words: "paypal.com") >= .doubtful)  // the same name under a cheap ending is not "the same owner"
    }

    /// An OAuth hop between one company's own domains, and a link to a page of the same site, are not "passing through another address".
    /// What the alert prints: a brand as people write it (arXiv, PayPal), and one reason once even when two rules found the same trick.
    @Test func reasonsNameTheBrandAsPeopleWriteItAndDoNotRepeatThemselves() {
        let look = SourceCheck.assess(url: "https://arxiv-submit.org/", words: "arXiv").reasons
        #expect(look.contains { $0.contains("not arXiv's") } && !look.contains { $0.contains("Arxiv") }, "\(look)")
        let pay = SourceCheck.assess(url: "https://paypal.com.evil-site.xyz/login", words: "").reasons
        #expect(pay.contains { $0.contains("PayPal") } || pay.contains { $0.contains("paypal.com") }, "\(pay)")
        #expect(!SourceCheck.assess(url: "https://paypal-login.evil-site.xyz/", words: "").reasons.contains { $0.contains("Paypal") })
        let spoof = SourceCheck.assess(url: "https://login.microsoftonline.com.evil-site.xyz/common/oauth2", words: "Sign in to Microsoft").reasons
        #expect(spoof.filter { $0.contains("in front of another domain") }.count == 1, "\(spoof)")
        #expect(SourceCheck.assess(url: "https://login.microsoftonline.com.evil-site.xyz/common/oauth2", words: "").level == .scam)
    }

    @Test func aRedirectBetweenTheSameOwnersDomainsIsNotAHop() {
        #expect(level("https://login.microsoftonline.com/common/oauth2/authorize?client_id=abc&redirect_uri=https%3A%2F%2Fteams.microsoft.com") == .ordinary)
        #expect(level("https://accounts.google.com/ServiceLogin?continue=https://mail.google.com/mail") == .ordinary)
        #expect(level("https://moodle.mbzuai.ac.ae/login/index.php?redirect=https://moodle.mbzuai.ac.ae/my/") <= .ordinary)
        #expect(level("https://accounts.google.com/o/oauth2/v2/auth?redirect_uri=https%3A%2F%2Fexample.com") == .doubtful)  // to a stranger: a warning
    }

    @Test func linkWordsThatMatchTheTargetOrNameNoSiteAreFine() {
        #expect(level("https://arxiv.org/abs/2410.01234", words: "arxiv.org/abs/2410.01234") == .official)
        #expect(level("https://export.arxiv.org/abs/1", words: "www.arxiv.org") == .official)
        #expect(level("https://www.nus.edu.sg/", words: "nus.edu.sg") == .official)
        #expect(level("https://youtu.be/dQw4w9WgXcQ", words: "youtube.com/watch?v=dQw4w9WgXcQ") == .ordinary)
        #expect(level("https://dl.acm.org/doi/10.1145/3544548.3581388", words: "doi.org/10.1145/3544548.3581388") == .official)
        #expect(level("https://doi.org/10.1038/s41586-021-03819-2", words: "nature.com") == .official)
        for words in ["the paper", "Click here", "Dr. Smith's notes", "e.g. this one", "report.pdf", "Node.js docs", "v2.0.1", "ASP.NET Core docs", "Character.AI raises $150M",
                      "[cs.AI] Attention Is All You Need", "math.CO preprint on graph colouring", "main.py", "README.md", "Fig.1.in the paper"] {
            #expect(level("https://example.com/x", words: words) == .ordinary, "\(words)")
        }
    }

    // MARK: the pieces

    @Test func punycodeDecodesTheRFCExamplesAndRefusesGarbage() {
        #expect(SourceCheck.punycode("bcher-kva") == "bücher")
        #expect(SourceCheck.punycode("maana-pta") == "mañana")
        #expect(SourceCheck.punycode("pple-43d") == "\u{0430}pple")
        #expect(SourceCheck.punycode("") == "")
        #expect(SourceCheck.punycode("ab_c") == nil && SourceCheck.punycode("é") == nil)
        #expect(SourceCheck.punycode("99999999999") == nil)  // overflows
    }

    @Test func aPunycodeLabelThatIsPlainLatinOrAWholeOtherWordIsNotAScam() {
        #expect(level("https://xn--bcher-kva.example/") <= .ordinary)  // bücher
        #expect(level("https://xn--80ak6aa92e.com/") == .scam)  // all Cyrillic look-alikes for "apple"
        #expect(level("https://xn--d1acpjx3f.xn--p1ai/") <= .ordinary)  // яндекс.рф: a real Russian word, no Latin twin
    }

    @Test func registrableDomainsKeepCountrySuffixesAndFreeHosting() {
        #expect(SourceCheck.registrable(of: "www.example.com") == "example.com")
        #expect(SourceCheck.registrable(of: "a.b.example.co.uk") == "example.co.uk")
        #expect(SourceCheck.registrable(of: "www.mbzuai.ac.ae") == "mbzuai.ac.ae")
        #expect(SourceCheck.registrable(of: "my.team.github.io") == "github.io")
        #expect(SourceCheck.registrable(of: "sites.google.com") == "sites.google.com")
        #expect(SourceCheck.registrable(of: "example.com.") == "example.com")
    }

    @Test func oneEditMeansExactlyOne() {
        #expect(SourceCheck.oneEdit("linkedln", "linkedin") && SourceCheck.oneEdit("micosoft", "microsoft") && SourceCheck.oneEdit("microsfot", "microsoft"))
        #expect(SourceCheck.oneEdit("microsofts", "microsoft"))
        #expect(!SourceCheck.oneEdit("microsoft", "microsoft") && !SourceCheck.oneEdit("micro", "microsoft") && !SourceCheck.oneEdit("mircosfot", "microsoft"))
    }

    @Test func theVerdictIsTheSameEveryTime() {
        let url = "https://login-microsoft-office365-paypal.top/x"
        let first = SourceCheck.assess(url: url)
        for _ in 0..<20 { #expect(SourceCheck.assess(url: url) == first) }
    }

    // MARK: the alert text

    @Test func theAlertSaysWhatWasFound() {
        #expect(SourceCheck.linkNotice(url: "mailto:a@b.example") == nil)
        #expect(SourceCheck.linkNotice(url: "https://arxiv.org/abs/1")?.hasPrefix("✓ A primary source (arxiv.org)") == true)
        #expect(SourceCheck.linkNotice(url: "https://example.org/x")?.contains("Not on Robo's list of known sources") == true)
        let scam = SourceCheck.linkNotice(url: "https://paypal.com.evil.xyz/login") ?? ""
        #expect(scam.hasPrefix("⚠ This looks like a scam.") && scam.contains("• "))
        let careful = SourceCheck.linkNotice(url: "https://bit.ly/abc") ?? ""
        #expect(careful.hasPrefix("⚠ Be careful with this link.") && careful.contains("shortened"))
        #expect(SourceCheck.linkNotice(url: "https://github.com/a/b")?.contains("Written by anyone") == true)
        #expect((SourceCheck.linkNotice(url: "https://evil.example/x", words: "paypal.com") ?? "").contains("The link says"))
    }
}

@Suite struct SourceCheckOfferTests {
    @Test func theEmployersOwnSiteIsOfficialAndAnUnrelatedOneIsDoubtful() {
        let own = SourceCheck.assess(offer(url: "https://careers.google.com/jobs/1", company: "Google"))
        #expect(own.level == .official && own.notes.contains("the employer's own site"))
        let tiktok = SourceCheck.assess(offer(url: "https://lifeattiktok.com/search/1", company: "TikTok"))
        #expect(tiktok.level <= .ordinary && !tiktok.warns, "\(tiktok)")  // its second domain is on the brand list
        let board = SourceCheck.assess(offer(url: "https://jobs.ashbyhq.com/acme/1", company: "Acme"))
        #expect(board.level == .ordinary)
        let stranger = SourceCheck.assess(offer(url: "https://apply.example.org/j", company: "Acme"))
        #expect(stranger.level == .doubtful && stranger.reasons.contains { $0.contains("not Acme's own site or a known job board") })
    }

    /// Real companies whose domain is not the literal name (found on 2,000 real postings): a shorter form, the initials, the name and a
    /// corporate ending. Not any prefix: a name with a jobs word on a different ending is still doubtful.
    @Test(arguments: [
        ("Datadog", "careers.datadoghq.com"), ("Illinois Tool Works", "careers.itw.com"), ("Tower Research Capital", "www.tower-research.com"),
        ("Muru", "www.murumed.com"), ("Clyde Companies", "careers.clydeinc.com"), ("Akuna Capital University", "www.akunacapital.com"),
        ("Arthur J. Gallagher & Co.", "jobs.ajg.com"), ("Advanced Energy", "jobs.advanced-energy.com"), ("Netflix", "explore.jobs.netflix.net"),
        ("NVIDIA", "nvidia.wd5.myworkdayjobs.com"),
    ])
    func aCompanysOwnDomainInItsUsualFormsIsNotDoubtful(company: String, host: String) {
        let v = SourceCheck.assess(offer(url: "https://\(host)/jobs/1", company: company))
        #expect(v.level <= .ordinary, "\(company) at \(host): \(v)")
    }

    @Test(arguments: [("Stripe", "stripe-jobs.xyz"), ("Stripe", "stripejobs.xyz"), ("Acme", "acme-hiring-now.com"), ("Datadog", "datadog-careers.top"), ("Google", "google-careers.xyz")])
    func aLookAlikeOfACompanysNameIsStillDoubtfulOrWorse(company: String, host: String) {
        let v = SourceCheck.assess(offer(url: "https://\(host)/apply", company: company))
        #expect(v.level >= .doubtful, "\(company) at \(host): \(v)")
    }

    @Test func aPreprintIsSaidToBeOne() {
        let paper = SourceCheck.assess(offer(.paper, title: "A paper", url: "https://arxiv.org/abs/2410.01234", company: nil))
        #expect(paper.level == .official && paper.notes.contains("a preprint: not peer reviewed"))
        let journal = SourceCheck.assess(offer(.paper, title: "A paper", url: "https://www.nature.com/articles/x", company: nil))
        #expect(!journal.notes.contains("a preprint: not peer reviewed"))
    }

    @Test func wordingThatAsksForIDOrMoneyInAnOfferIsAScam() {
        for text in [
            "Send a photo of your passport and bank details to apply", "Pay with gift cards for your starter kit", "Interview on WhatsApp only, message our recruiter",
            "Contact the recruiter via Telegram to apply", "Guaranteed job placement after the course", "Earn $300 per day from home", "No experience needed, earn $500 per week",
            "You must pay for your own equipment before your first day", "Make a crypto deposit to unlock the position", "A visa processing fee is due before the contract",
            // the red team's: "no" in the same clause used to switch every rule off; synonyms; other spellings; split across fields
            "No experience needed - send your bank account details to start", "Do not delay: send your bank details today", "Not a scam, send us your credit card number",
            "No worries, interview on WhatsApp", "No interview needed: instant offer letter", "Assured job after the 3-day course", "Earn $500 daily, no experience needed",
            "Buy iTunes cards worth $200 for your starter equipment", "Send us your seed phrase to verify the account", "Reply with your IBAN and routing number",
            "Send your b\u{0430}nk details", "Send your \u{FF42}\u{FF41}\u{FF4E}\u{FF4B} details", "Send your bank d\u{00E9}tails", "Pay by Western Union to secure your place",
            "Add our recruiter on WhatsApp +971 50 000 0000", "WhatsApp +971 50 000 0000 to start",
            // the hunter's control set: money by a route that cannot be undone, a fee paid by YOU, crypto to "start earning"
            "Send money by wire transfer to secure your seat.", "Western Union payment required.", "You must pay a visa fee of $300 before we send the contract.",
            "We need you to pay a visa fee.", "We need you to pay for your own equipment.", "Invest in Bitcoin to start earning.", "You only pay for your own training kit",
        ] {
            let v = SourceCheck.assess(offer(title: text))
            #expect(v.level == .scam && v.hidden, "\(text): \(v)")
        }
    }

    /// Prizes that must be paid for, wallets to connect, fake cheques: scams in a contest as much as in a job. Spaced-out letters and
    /// look-alike symbols do not hide a rule either.
    @Test func prizeWalletAndChequeScamsAreCaughtInEveryKindAndTrickedSpellingsToo() {
        for text in ["Pay tax first to release the prize money", "Winners must pay customs clearance to receive the prize", "A shipping and handling charge applies to release your prize"] {
            for kind in [RadarItem.Kind.internship, .hackathon, .contest, .program] {
                let v = SourceCheck.assess(offer(kind, title: "Prize", url: "https://prize.example.org/", company: nil, snippet: text))
                #expect(v.level == .scam, "\(kind): \(text): \(v)")
            }
        }
        for text in ["Connect your MetaMask wallet to claim your hackathon prize", "Claim your NFT prize: connect wallet and approve the transaction"] {
            #expect(SourceCheck.assess(offer(.hackathon, title: "Prize", url: "https://prize.example.org/", company: nil, snippet: text)).level == .doubtful, "\(text)")
            #expect(SourceCheck.assess(offer(snippet: text)).level == .scam, "\(text)")
        }
        for text in ["We will mail you a check to purchase your home-office equipment", "Reach HR at hr.recruiter.official@gmail.com", "Questions? Text +1 555 0100 (WhatsApp only)",
                     "Complete simple online tasks, get paid daily", "Stipend $8000/month for undergraduates, no interview, no experience", "Job assured after the 3-day course",
                     "Confirm your card number to verify your age", "Submit your ID proof and a selfie holding your ID", "Send your b@nk details", "Pay with g1ft cards",
                     "Interview on W h a t s A p p", "Interview on Wh@tsApp", "Pay the registrati0n fee: send money by wire transfer", "Never miss a chance: pay by wire transfer today"] {
            let v = SourceCheck.assess(offer(snippet: text))
            #expect(v.level == .scam || text.contains("registrati0n") && v.level >= .doubtful, "\(text): \(v)")
        }
        // "without further ado" is not a denial
        #expect(SourceCheck.assess(offer(snippet: "Without further ado, you must pay for your own laptop from our vendor")).level == .scam)
        #expect(SourceCheck.assess(offer(snippet: "Salary is paid weekly in USDT")).level == .doubtful)
    }

    @Test func wordingThatDeniesItIsNotAScam() {
        for text in [
            "We will never ask you to send your passport or bank details.", "No application fee.", "Never pay to be hired: we do not charge any fee.",
            "There is no registration fee and no deposit.", "We do not use WhatsApp or Telegram for interviews.", "Do not send gift cards to anyone.",
        ] {
            let v = SourceCheck.assess(offer(.program, title: "Summer research programme", snippet: text))
            #expect(v.level <= .ordinary, "\(text): \(v)")
        }
    }

    @Test func aDenialInAnEarlierSentenceOrClauseDoesNotCancelALaterScamSentence() {
        let v = SourceCheck.assess(offer(title: "No experience needed. Earn $300 per day from home"))
        #expect(v.level == .scam, "\(v)")
        let w = SourceCheck.assess(offer(snippet: "We never ask for money. Send your bank details to our recruiter."))
        #expect(w.level == .scam, "\(w)")
        // a bare "no" in the same clause is not a denial: "no fee, no interview, just send ..."
        let x = SourceCheck.assess(offer(snippet: "No fee, no interview, just send us your bank account number"))
        #expect(x.level == .scam, "\(x)")
        let noPunctuation = SourceCheck.assess(offer(snippet: "No interview just send your bank details to start"))
        #expect(noPunctuation.level == .scam, "\(noPunctuation)")
        // ID alone is only worth a warning: employers do ask for a passport copy once there is an offer
        let y = SourceCheck.assess(offer(snippet: "We never ask for money. Send your passport to our recruiter."))
        #expect(y.level == .doubtful, "\(y)")
    }

    @Test func aFeeIsDoubtfulNotHiddenAndHurryNeedsASecondSignal() {
        let fee = SourceCheck.assess(offer(.contest, title: "Spring hackathon", url: "https://hack.example.org/", company: nil, snippet: "A $20 registration fee applies."))
        #expect(fee.level == .doubtful && fee.reasons.contains { $0.contains("fee") }, "\(fee)")
        let hurry = SourceCheck.assess(offer(title: "Urgent hiring: limited seats, apply now to secure your place"))
        #expect(hurry.level <= .ordinary, "\(hurry)")  // routine in real postings, so one such phrase is only a hint
        let two = SourceCheck.assess(offer(title: "Urgent hiring! Act now, hurry"))
        #expect(two.level == .doubtful, "\(two)")
        let shout = SourceCheck.assess(offer(title: "GREAT INTERNSHIP OPPORTUNITY FOR EVERYONE"))
        #expect(shout.level <= .ordinary, "\(shout)")  // all-capitals titles are normal for ATS postings and contests
        let shoutAndHurry = SourceCheck.assess(offer(title: "GREAT INTERNSHIP OPPORTUNITY!!! ACT NOW"))
        #expect(shoutAndHurry.level == .doubtful, "\(shoutAndHurry)")
    }

    /// Real wording from postings, contests and student clubs that the first version hid or flagged (found by the false-positive hunter).
    @Test func ordinaryWordingInRealPostingsAndEventsIsNotFlagged() {
        let jobs = [
            "We pay for your training and equipment.", "Company will pay for your laptop and software.", "We'll buy you your own laptop.",
            "If you have been selected for the programme you will receive an email.", "100% risk-free cancellation.",
            "Please submit your passport copy after the offer is accepted for visa processing.", "Provide your national ID number for the background check.",
            "Please send a copy of your passport to process your work visa.", "Send an invitation letter request with your passport copy.",
            "Upload your ID card for identity verification via the portal after you accept.", "The company covers relocation costs, visa fee and flights.",
            "Work on signal processing and apply machine learning to sensor data.", "Digital Signal Processing Intern: apply your skills, contact the lab",
            "Follow our official WeChat account to apply.", "We interview via Zoom, never via WhatsApp or Telegram.", "We interview on Teams and never through WhatsApp.",
            "Guaranteed interview scheme: applicants with a disability who meet the minimum criteria are guaranteed an interview.",
            "Relocation and visa fee covered by the company.", "We reimburse the visa fee.", "The visa fee is paid by the employer.",
            "No experience required, $22 per hour, remote.", "No experience required, paid $30/hour.", "Application fee: none.", "Registration fee: free.",
            "Software Engineer Intern, Crypto Trading Platform", "SOFTWARE ENGINEER INTERN SUMMER 2027", "Immediate start. Remote from home option.", "Limited spots available. Register early!",
            "Please don\u{2019}t send your passport or bank details to anyone", "Our company doesn\u{2019}t ask you to send a gift card or a wire transfer",
        ]
        for text in jobs {
            let v = SourceCheck.assess(offer(title: "Intern", snippet: text))
            #expect(v.level <= .ordinary || text.contains("WeChat"), "\(text): \(v)")
        }
        #expect(SourceCheck.assess(offer(title: "Intern", snippet: "Follow our official WeChat account to apply.")).level == .doubtful)
        let events = [
            "Join our Telegram group to chat with other participants.", "Join the WhatsApp group chat for updates.", "Contact us on WhatsApp for sponsorship",
            "Top 3 teams win $50 Amazon gift cards.", "Prizes: gift cards and swag.", "Prize money is paid by wire transfer within 30 days.", "Build an Ethereum wallet in 24 hours.",
            "Prizes paid in USDT payout to winners.", "Upload a copy of your student ID card as proof of enrollment.", "Submit proof of enrollment (student ID card or transcript).",
            "Application fee waived for students.", "Guaranteed admission for all finalists.", "NVIDIA GTC AI HACKATHON",
        ]
        for text in events {
            let v = SourceCheck.assess(offer(.hackathon, title: "Spring hackathon", url: "https://hack.example.org/", company: nil, snippet: text))
            #expect(v.level <= .ordinary || text.contains("admission"), "\(text): \(v)")
        }
    }

    /// The offer's company comes from the same feed as its address, so it must never be able to vouch for it (red team: every one of
    /// these came back official).
    @Test func aCompanyNameInTheFeedCannotVouchForItsOwnAddress() {
        for (company, host) in [("NVIDIA", "nvidia-careers.com"), ("NVIDIA", "nvidia-jobs.net"), ("Microsoft", "microsoft-careers.org"), ("Microsoft", "microsoft-inc.com"),
                                ("Stripe", "stripe-jobs.com"), ("Google", "google-inc.com"), ("Anthropic", "anthropic.co"), ("Stripe", "stripe.work"), ("Zxq Dynamics", "zxq-jobs.com")] {
            let v = SourceCheck.assess(offer(url: "https://\(host)/apply", company: company))
            #expect(v.level >= .doubtful, "\(company) at \(host): \(v)")
        }
        for (company, host) in [("PayPal Login", "paypal-login.com"), ("Microsoft Account Security", "microsoft-account-security.com"), ("Apple ID Support", "appleid-support.com"),
                                ("Microsoft Evilco", "login.microsoftonline.com.evilco.net"), ("PayPal Evilco", "paypal.evilco.com")] {
            #expect(SourceCheck.assess(offer(url: "https://\(host)/apply", company: company)).level == .scam, "\(company) at \(host)")
        }
        // a bucket or a tenant is not the brand's own site
        for (company, host) in [("Amazon", "evil-bucket.s3.amazonaws.com"), ("Microsoft", "evilcorp.sharepoint.com"), ("Google", "storage.googleapis.com"), ("Dropbox", "evil.dropboxusercontent.com")] {
            #expect(SourceCheck.assess(offer(url: "https://\(host)/apply.html", company: company)).level != .official, "\(company) at \(host)")
        }
        // a domain that matches the company's name is a note, never a green mark
        let acme = SourceCheck.assess(offer(url: "https://careers.acmerobotics.com/jobs/1", company: "Acme Robotics"))
        #expect(acme.level == .ordinary && acme.notes.contains { $0.contains("matches the employer's name") }, "\(acme)")
    }

    /// A long text must cost a long text, not a long time (the first version took seconds to minutes on a few thousand characters).
    @Test func hostileLongInputsAreFast() {
        let started = Date()
        let inputs = [String(repeating: "a", count: 20_000), String(repeating: "a.", count: 5_000), String(repeating: "www.", count: 2_500), String(repeating: "send ", count: 400),
                      String(repeating: "interview on ", count: 150), String(repeating: "gift ", count: 400), String(repeating: "!", count: 3_000)]
        for text in inputs {
            _ = SourceCheck.assess(url: "https://example.com/", words: text)
            _ = SourceCheck.assess(offer(title: String(text.prefix(200)), snippet: String(text.prefix(2_000))))
        }
        _ = SourceCheck.assess(url: "https://" + String(repeating: "a.", count: 2_000) + "com/")
        #expect(Date().timeIntervalSince(started) < 3, "took \(Date().timeIntervalSince(started)) s")
    }

    /// What goes into a reason from outside (the host, the words) cannot carry a line break or a look-alike check mark.
    @Test func textFromOutsideCannotBreakTheAlert() {
        let v = SourceCheck.assess(url: "https://evil.example%0A%E2%9C%93%20Official%20university%20site.arxiv.org/")
        #expect(v.level == .scam && !v.reasons.joined().contains("\n") && !v.host.contains("\n"), "\(v)")
        let w = SourceCheck.assess(url: "https://evil.example/x", words: "paypal.com\u{200B}\n✓ official")
        #expect(!w.reasons.joined().contains("\n"), "\(w)")
    }

    @Test func theSameWordsInANewsHeadlineOrAPaperAreNotScanned() {
        for kind in [RadarItem.Kind.news, .paper] {
            let v = SourceCheck.assess(offer(kind, title: "Scammers asked victims to send a passport and pay with gift cards", url: "https://www.example.org/story", company: nil))
            #expect(v.level <= .ordinary, "\(kind): \(v)")
        }
    }

    @Test func aPlainOfferIsClean() {
        for title in ["Software Engineer Intern - Summer 2027", "Research Intern, Computer Vision", "Machine Learning Engineer (New Grad)", "ByteDance Student Researcher - Large Language Model"] {
            #expect(SourceCheck.assess(offer(title: title, url: "https://boards.greenhouse.io/acme/jobs/1", company: "Acme")).level <= .ordinary, "\(title)")
        }
    }

    @Test func theCuratedProgrammesAreNeverFlagged() {
        #expect(!Programmes.all.isEmpty)
        for p in Programmes.all {
            let v = SourceCheck.assess(p)
            #expect(v.level <= .ordinary, "\(p.title) \(p.url): \(v)")
        }
    }
}
