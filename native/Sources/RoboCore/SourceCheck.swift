// Is this a source to believe? Pure and offline: the address and the words around it come in, a verdict goes out. No request is ever made,
// so no address Robo looks at leaves the Mac, and nothing here can be slowed or fooled by the page itself.
//
// What it can and cannot tell. It reads the SHAPE of an address and the wording of an offer: look-alike characters, a brand's name on a
// domain the brand does not own, a shortened or chat/form link, a link whose words name another site than its target, and the wording
// scams use for jobs and prizes (fees, ID, gift cards, a WhatsApp interview). It cannot know that a clean-looking new domain is a scam, and
// a list of "official" sources proves only the host, not the page. `official` therefore means "a host Robo knows to be a primary or
// institutional source, with nothing odd about the address", never "true". There is deliberately no list of untrustworthy publishers: who
// counts as one is contested and would need upkeep nobody does; a blog or a forum is marked "written by anyone" instead, and a preprint
// "not peer reviewed". The company name of a listing comes from the same feed as its link, so it can never make a link official: only a
// domain the brand list gives that company does.
//
// Levels (`Level`): official < ordinary < doubtful < scam. `scam` is only for strong, specific signals (a name@ in the address, a numeric
// address, letters that imitate another script, `login.paypal.com.evil.xyz`, wording that asks for ID or gift cards): the radar never shows
// it. `doubtful` is a sum of weaker signals: the radar shows it with the reasons, below the clean items, and never as a popup of its own.
// What a warning is worth depends on where the address comes from (`Context`): a link in a reply, an article, an event (contest, hackathon,
// programme: student clubs use free hosting, forms and chat groups) or a job (an employer has its own site and never needs your ID).
//
// Lists (`primary`, `boards`, `tenants`, `brands` with their owners, `hosting`, `shorteners`, `offPlatform`) are dated `verified`. Every rule
// was tried on real data (2,000 real internship postings, the 20,000 most visited domains, Hacker News links, a live phishing feed) and
// attacked by independent reviewers; CLAUDE.md says how to repeat that after a change.
import Foundation

public enum SourceCheck {
    public enum Level: Int, Comparable, Sendable {
        case official, ordinary, doubtful, scam
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Verdict: Equatable, Sendable {
        public var level: Level
        /// Why it is doubtful or a scam, the strongest first, as sentences. A mild reason can also sit on an ordinary source.
        public var reasons: [String]
        /// What is worth knowing besides: "a primary source", "written by anyone", "a preprint". Only on sources that are not doubtful.
        public var notes: [String]
        public var host: String
        /// Never shown.
        public var hidden: Bool { level == .scam }
        /// Shown with a warning.
        public var warns: Bool { level >= .doubtful }
    }

    /// Where an address comes from decides how much a warning is worth.
    enum Context { case link, article, event, job }

    /// When the lists below were last read against the real world: re-check them now and then.
    public static let verified = "2026-10-21"

    // MARK: the lists

    /// Hosts Robo knows as a primary or institutional source: publishers and preprint servers, standards bodies, the organisers of the
    /// contests it lists, programmes it lists. Registrable domains; `.edu`, `.gov` and `.ac.xx` hosts are official by their ending.
    static let primary: Set<String> = [
        "arxiv.org", "biorxiv.org", "medrxiv.org", "chemrxiv.org", "ssrn.com", "techrxiv.org", "openreview.net", "aclanthology.org",
        "neurips.cc", "nips.cc", "icml.cc", "iclr.cc", "mlr.press", "thecvf.com", "jmlr.org", "doi.org", "semanticscholar.org",
        "acm.org", "ieee.org", "springer.com", "nature.com", "science.org", "sciencedirect.com", "elsevier.com", "wiley.com", "plos.org",
        "pnas.org", "w3.org", "ietf.org", "rfc-editor.org", "iso.org", "ctftime.org", "codeforces.com", "mlh.io", "outreachy.org",
        "daad.de", "mitacs.ca", "cern.ch", "ukri.org", "europa.eu", "un.org", "who.int", "oecd.org", "worldbank.org",
    ]
    static let preprint: Set<String> = ["arxiv.org", "biorxiv.org", "medrxiv.org", "chemrxiv.org", "ssrn.com", "techrxiv.org", "researchsquare.com", "preprints.org"]

    /// Job-board platforms: a real board, but anyone can open one, so this only says "not a stranger's page".
    static let boards: Set<String> = [
        "greenhouse.io", "lever.co", "ashbyhq.com", "workable.com", "smartrecruiters.com", "myworkdayjobs.com", "icims.com", "jobvite.com",
        "taleo.net", "successfactors.com", "successfactors.eu", "bamboohr.com", "recruitee.com", "breezy.hr", "teamtailor.com", "pinpointhq.com",
        "applytojob.com", "eightfold.ai", "avature.net", "phenompeople.com", "ultipro.com", "paylocity.com", "dayforcehcm.com", "oraclecloud.com",
        "rippling.com", "join.com", "linkedin.com", "indeed.com", "glassdoor.com", "joinhandshake.com", "wellfound.com",
        "myworkdaysite.com", "yello.co", "recsolu.com", "applicantpro.com", "careerpuck.com", "grnh.se", "hirebridge.com", "adp.com", "ukg.com",
        "peopleadmin.com", "governmentjobs.com", "jobscore.com", "hrmdirect.com", "csod.com", "brassring.com", "kenexa.com", "ripplehire.com",
        "gusto.com", "dover.com", "zohorecruit.com", "jazz.co", "workatastartup.com", "welcometothejungle.com", "tal.net", "personio.de",
        "softgarden.io", "comeet.com", "freshteam.com", "homerun.co", "bayt.com", "naukrigulf.com", "gulftalent.com",
    ]

    /// Services where an organisation has a name of its own under the vendor's domain (`mbzuai.zoom.us`, `acme.okta.com`): a brand's name
    /// before them is how they work, unless it sits beside a login word.
    static let tenants: Set<String> = [
        "sharepoint.com", "zoom.us", "zoom.com", "webex.com", "instructure.com", "service-now.com", "atlassian.net", "atlassian.com", "slack.com",
        "qualtrics.com", "skilljar.com", "feishu.cn", "larkoffice.com", "zendesk.com", "force.com", "salesforce.com", "okta.com", "oktapreview.com",
        "azure.com", "microsoftonline.com", "office365.com", "office.com", "box.com", "notion.so", "airtable.com", "hubspot.com", "docusign.net",
        "myshopify.com", "canvaslms.com", "blackboard.com", "moodlecloud.com", "gitbook.io", "readthedocs.io", "sentry.io",
        "eventbuilder.com", "eventbrite.com", "cvent.com", "on24.com", "bigmarker.com", "hopin.com", "swoogo.events", "goldcast.io", "brandlive.com",
    ]

    /// Places where anyone can publish: not a judgement of the writer, a fact about the place.
    static let userWritten: Set<String> = [
        "medium.com", "substack.com", "reddit.com", "quora.com", "x.com", "twitter.com", "facebook.com", "youtube.com", "youtu.be", "tiktok.com",
        "instagram.com", "wordpress.com", "blogspot.com", "dev.to", "hashnode.dev", "ghost.io", "notion.site", "github.io", "gitlab.io",
        "stackexchange.com", "stackoverflow.com", "ycombinator.com", "lesswrong.com", "github.com", "weebly.com", "wixsite.com", "carrd.co",
    ]

    /// Hosting where the label before the platform, or the file's folder, is whatever the visitor chose: a brand's name there proves nothing,
    /// and most live phishing sits there. (Blogs on `github.io`, `wordpress.com` are ordinary.)
    static let hosting: Set<String> = [
        "github.io", "gitlab.io", "netlify.app", "vercel.app", "pages.dev", "workers.dev", "herokuapp.com", "web.app", "firebaseapp.com", "blogspot.com",
        "wordpress.com", "wixsite.com", "weebly.com", "carrd.co", "notion.site", "webflow.io", "glitch.me", "repl.co", "onrender.com", "fly.dev",
        "azurewebsites.net", "appspot.com", "ngrok.io", "ngrok-free.app", "trycloudflare.com", "000webhostapp.com", "squarespace.com", "bubbleapps.io",
        "godaddysites.com", "canva.site", "mystrikingly.com", "typedream.app", "framer.website", "sites.google.com", "mybluehost.me", "infinityfreeapp.com",
        "epizy.com", "rf.gd", "yolasite.com", "jimdofree.com", "webnode.page", "site123.me", "wixstudio.io", "weeblysite.com",
        // file and bucket hosts: the page can be anyone's
        "amazonaws.com", "windows.net", "googleapis.com", "googleusercontent.com", "dropboxusercontent.com", "onmicrosoft.com", "azureedge.net",
        "cloudfront.net", "r2.dev", "replit.app", "streamlit.app", "hf.space", "surge.sh", "azurestaticapps.net", "ipfs.io", "dweb.link",
        "cloudflare-ipfs.com", "eth.limo", "oaiusercontent.com",
    ]
    /// Hosting that carries ordinary blogs and project pages (a note, not a warning).
    static let ordinaryHosting: Set<String> = ["github.io", "gitlab.io", "blogspot.com", "wordpress.com", "amazonaws.com", "googleapis.com", "googleusercontent.com", "cloudfront.net", "windows.net", "azureedge.net"]

    /// You cannot see where these go.
    static let shorteners: Set<String> = [
        "bit.ly", "bitly.com", "tinyurl.com", "t.co", "goo.gl", "ow.ly", "is.gd", "cutt.ly", "rb.gy", "shorturl.at", "buff.ly", "lnkd.in", "rebrand.ly", "tiny.cc",
        "trib.al", "s.id", "t.ly", "v.gd", "bl.ink", "short.io", "clck.ru", "soo.gd", "adf.ly", "bc.vc", "bit.do", "qrco.de", "ouo.io", "tr.ee", "dub.sh",
        "smarturl.it", "tiny.one", "page.link", "lnk.bio", "shrtco.de", "cutt.us", "zpr.io", "urlzs.com", "lc.cx", "ln.run",
    ]

    /// Talking to a "recruiter" in a chat app, or filling in a form, is how most job scams run. Hosts or registrable domains.
    static let offPlatform: Set<String> = [
        "t.me", "telegram.me", "wa.me", "chat.whatsapp.com", "api.whatsapp.com", "web.whatsapp.com", "signal.group", "discord.gg", "line.me", "zalo.me",
        "invite.viber.com", "join.skype.com", "linktr.ee", "forms.gle", "typeform.com", "tally.so", "jotform.com", "wa.link", "m.me", "signal.me", "open.kakao.com",
        "dsc.gg", "u.wechat.com", "telegram.dog", "lin.ee", "forms.office.com", "forms.microsoft.com", "surveymonkey.com", "cognitoforms.com", "forms.zohopublic.com", "paperform.co",
    ]

    /// Abused so often that the ending alone is worth a note; `.zip` and `.mov` also look like file names.
    static let riskyEndings: Set<String> = [
        "top", "xyz", "click", "buzz", "cfd", "sbs", "icu", "rest", "cyou", "monster", "quest", "gq", "tk", "ml", "ga", "cf", "loan", "date",
        "work", "vip", "bid", "win", "su", "ws", "cc", "pw", "link", "support", "help", "kim", "men", "stream", "download", "racing", "review", "party", "trade",
    ]
    static let fileEndings: Set<String> = ["zip", "mov"]
    /// Country endings that anyone can register and that scammers use freely: a brand's name under one of them is not the brand's. (Every
    /// other two-letter ending is a country the big brands really are in: google.ae, google.com.pe, amazon.de.)
    static let openEndings: Set<String> = ["cc", "co", "pw", "ws", "su", "to", "tv", "me", "vu", "nu", "ly", "io", "ai", "sh", "tk", "ml", "ga", "cf", "gq"]
    /// Services that point a name at any address you like (`127.0.0.1.nip.io`).
    static let wildcardDNS: Set<String> = ["nip.io", "sslip.io", "xip.io", "traefik.me", "localtest.me", "lvh.me", "vcap.me"]
    static let codeHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org", "dev.azure.com", "ssh.dev.azure.com"]
    /// Resolvers and aliases: the same owner under two names, or an address whose job is to lead to the publisher.
    static let resolvers: Set<String> = ["doi.org", "dx.doi.org", "handle.net", "hdl.handle.net"]
    static let aliasGroups: [Set<String>] = [
        ["youtu.be", "youtube.com"], ["x.com", "twitter.com", "t.co"], ["hf.co", "huggingface.co"], ["fb.me", "facebook.com"], ["lnkd.in", "linkedin.com"],
        ["arxiv.org", "ar5iv.org"], ["pypi.org", "python.org"], ["wikipedia.org", "wikimedia.org"],
    ]

    private static let microsoftDomains: Set<String> = [
        "microsoft.com", "microsoft.net", "microsoftonline.com", "office.com", "office365.com", "live.com", "outlook.com", "windows.com", "azure.com", "msn.com", "bing.com",
        "skype.com", "xbox.com", "visualstudio.com", "msft.net", "cloud.microsoft", "officeapps.live.com", "sharepointonline.com", "microsoft365.com",
        "microsoftazuread-sso.com", "microsoftonline.us", "office365.us", "microsoft.us", "vscode.dev",
    ]
    private static let googleDomains: Set<String> = [
        "google.com", "google.org", "google.dev", "google.net", "google.cat", "gmail.com", "googlemail.com", "youtube.com", "withgoogle.com", "gstatic.com", "goo.gl",
        "g.co", "abc.xyz", "ggpht.com", "ytimg.com", "googletagmanager.com", "google-analytics.com", "googlesyndication.com", "googleadservices.com",
        "doubleclick.net", "android.com", "chromium.org", "blogger.com", "deepmind.com", "tensorflow.org", "firebase.com", "flutter.dev", "golang.org", "web.dev",
    ]
    private static let appleDomains: Set<String> = ["apple.com", "icloud.com", "me.com", "mzstatic.com", "cdn-apple.com", "apple.news", "icloud-content.com"]
    private static let metaDomains: Set<String> = [
        "facebook.com", "facebook.net", "fb.com", "fb.me", "fbcdn.net", "messenger.com", "meta.com", "instagram.com", "cdninstagram.com", "whatsapp.com", "whatsapp.net", "wa.me", "oculus.com",
        "metacareers.com",
    ]
    private static let openAIDomains: Set<String> = ["openai.com", "openai.org", "chatgpt.com", "oaistatic.com"]

    /// A name people imitate, with every registrable domain its owner uses (a country ending from `brandCountries` is allowed on top).
    static let brands: [String: Set<String>] = [
        "paypal": ["paypal.com", "paypal.me", "paypalobjects.com"],
        "microsoft": microsoftDomains, "outlook": microsoftDomains, "office365": microsoftDomains, "microsoft365": microsoftDomains,
        "microsoftonline": microsoftDomains, "onedrive": microsoftDomains.union(["onedrive.com"]),
        "google": googleDomains, "gmail": googleDomains, "deepmind": googleDomains, "alphabet": googleDomains,
        "apple": appleDomains, "icloud": appleDomains,
        "amazon": ["amazon.com", "amazon.jobs", "amazon.science", "amazon.dev", "aboutamazon.com", "a2z.com", "media-amazon.com", "audible.com", "twitch.tv"],
        "netflix": ["netflix.com", "netflix.net", "nflxso.net", "nflximg.net", "nflxext.com", "nflxvideo.net"],
        "facebook": metaDomains, "instagram": metaDomains, "whatsapp": metaDomains,
        "linkedin": ["linkedin.com", "licdn.com", "lnkd.in"],
        "twitter": ["twitter.com", "x.com", "t.co", "twimg.com"],
        "github": ["github.com", "github.io", "githubusercontent.com", "github.blog", "githubassets.com", "githubapp.com", "github.dev", "github.community", "githubstatus.com"],
        "openai": openAIDomains, "chatgpt": openAIDomains,
        "anthropic": ["anthropic.com", "claude.ai", "claude.com"], "claude": ["anthropic.com", "claude.ai", "claude.com"],
        "nvidia": ["nvidia.com", "nvidiangc.com", "nvidia.cn", "nvidia.org"],
        "tesla": ["tesla.com", "teslamotors.com"],
        "binance": ["binance.com", "binance.us", "binance.org", "binance.info", "binance.vision", "bnbstatic.com"],
        "coinbase": ["coinbase.com", "cbhq.net"],
        "metamask": ["metamask.io", "consensys.net", "consensys.io"],
        "dropbox": ["dropbox.com", "dropboxstatic.com", "getdropbox.com"],
        "docusign": ["docusign.com", "docusign.net"],
        "zoom": ["zoom.us", "zoom.com", "zoomgov.com"],
        "adobe": ["adobe.com", "adobe.io", "adobelogin.com", "typekit.net", "behance.net"],
        "tiktok": ["tiktok.com", "tiktokv.com", "tiktokcdn.com", "lifeattiktok.com", "tiktokshop.com"],
        "bytedance": ["bytedance.com", "bytedance.net", "byteoversea.com", "lifeatbytedance.com", "joinbytedance.com"],
        "huawei": ["huawei.com", "huaweicloud.com", "hicloud.com", "dbankcloud.com", "vmall.com"],
        "samsung": ["samsung.com", "samsungcloud.com", "samsungapps.com", "samsungnext.com"],
        "indeed": ["indeed.com", "indeedcdn.com"],
        "glassdoor": ["glassdoor.com", "glassdoor.co.uk"],
        "deloitte": ["deloitte.com", "deloitteresources.com"],
        "mckinsey": ["mckinsey.com"],
        "kpmg": ["kpmg.com", "kpmg.us"],
        "pwc": ["pwc.com"],
        "jpmorgan": ["jpmorgan.com", "jpmorganchase.com", "chase.com"],
        "hsbc": ["hsbc.com", "hsbc.co.uk"],
        "moodle": ["moodle.org", "moodle.com", "moodlecloud.com", "moodle.net"],
        "mbzuai": ["mbzuai.ac.ae"],
        "telegram": ["telegram.org", "t.me", "telegram.me", "tg.dev", "telegram.dog"],
        "slack": ["slack.com", "slack-edge.com", "slack-files.com"],
        "notion": ["notion.so", "notion.com", "notion.site", "notion-static.com"],
        "coursera": ["coursera.org"], "udemy": ["udemy.com"], "kaggle": ["kaggle.com", "kaggleusercontent.com"], "overleaf": ["overleaf.com"],
        "huggingface": ["huggingface.co", "hf.co", "hf.space"],
        "stripe": ["stripe.com", "stripe.network", "stripecdn.com"], "revolut": ["revolut.com"],
        // the sources this module itself vouches for: a look-alike of one of them is worse than a look-alike of a shop
        "arxiv": ["arxiv.org"], "openreview": ["openreview.net"], "biorxiv": ["biorxiv.org"], "medrxiv": ["medrxiv.org"], "ctftime": ["ctftime.org"],
        "codeforces": ["codeforces.com"], "neurips": ["neurips.cc", "nips.cc"], "ieee": ["ieee.org"], "springer": ["springer.com", "springernature.com"],
        "sciencedirect": ["sciencedirect.com"], "semanticscholar": ["semanticscholar.org"], "aclanthology": ["aclanthology.org"],
        // banks (the reader is in the UAE) and Meta's job pages
        "wellsfargo": ["wellsfargo.com"], "bankofamerica": ["bankofamerica.com"], "citibank": ["citibank.com", "citi.com"], "emiratesnbd": ["emiratesnbd.com"],
        "adcb": ["adcb.com"], "mashreq": ["mashreqbank.com", "mashreq.com"], "etisalat": ["etisalat.ae", "eand.com"], "meta": metaDomains,
        // where wallets get drained
        "uniswap": ["uniswap.org", "uniswap.com"], "opensea": ["opensea.io"], "trustwallet": ["trustwallet.com"], "ledger": ["ledger.com"],
        "pancakeswap": ["pancakeswap.finance"], "kucoin": ["kucoin.com"], "bybit": ["bybit.com"],
    ]
    /// Names whose own name before another domain is a scam by itself (money, identity): `paypal.anything.com`. For others a name in front of
    /// a service is often a customer's own tenant (microsoft.eventbuilder.com), so it is only a warning.
    static let highRisk: Set<String> = [
        "paypal", "binance", "coinbase", "metamask", "docusign", "hsbc", "jpmorgan", "apple", "icloud", "revolut", "stripe",
        "uniswap", "opensea", "trustwallet", "ledger", "pancakeswap", "kucoin", "bybit", "wellsfargo", "bankofamerica", "citibank", "emiratesnbd", "adcb", "mashreq", "etisalat",
    ]
    /// How a brand is written in a reason: the name people know it by (arXiv, PayPal, OpenAI), not the lower-case key of the table.
    static func shown(_ brand: String) -> String {
        let written = ["arxiv": "arXiv", "biorxiv": "bioRxiv", "medrxiv": "medRxiv", "openreview": "OpenReview", "ctftime": "CTFtime", "ieee": "IEEE",
                       "neurips": "NeurIPS", "mbzuai": "MBZUAI", "paypal": "PayPal", "openai": "OpenAI", "chatgpt": "ChatGPT", "github": "GitHub",
                       "linkedin": "LinkedIn", "whatsapp": "WhatsApp", "tiktok": "TikTok", "docusign": "DocuSign", "metamask": "MetaMask",
                       "icloud": "iCloud", "onedrive": "OneDrive", "microsoftonline": "Microsoft", "office365": "Office 365", "microsoft365": "Microsoft 365",
                       "huggingface": "Hugging Face", "hsbc": "HSBC", "jpmorgan": "JPMorgan", "kpmg": "KPMG", "pwc": "PwC", "adcb": "ADCB",
                       "wellsfargo": "Wells Fargo", "bankofamerica": "Bank of America", "emiratesnbd": "Emirates NBD", "semanticscholar": "Semantic Scholar",
                       "aclanthology": "ACL Anthology", "sciencedirect": "ScienceDirect", "bytedance": "ByteDance", "deepmind": "DeepMind",
                       "opensea": "OpenSea", "trustwallet": "Trust Wallet", "pancakeswap": "PancakeSwap", "kucoin": "KuCoin",
                       "nvidia": "NVIDIA"]
        return written[brand] ?? brand.capitalized
    }
    /// The sources this module vouches for: a hyphenated look-alike of one (arxiv-submit.org) is a warning by itself.
    static let sourceBrands: Set<String> = ["arxiv", "openreview", "biorxiv", "medrxiv", "ctftime", "codeforces", "neurips", "ieee", "springer", "sciencedirect", "semanticscholar", "aclanthology", "mbzuai"]
    /// The reader's own school: a look-alike of it is aimed at them, so no country ending and no benefit of the doubt for a hyphenated name.
    static let personalBrands: Set<String> = ["mbzuai"]
    /// Ordinary words that are also a company's or site's name: on their own they are only a hint, and one letter off is no proof.
    static let wordBrands: Set<String> = ["apple", "amazon", "zoom", "adobe", "tesla", "indeed", "pwc", "outlook", "moodle", "claude", "slack", "notion", "stripe", "overleaf", "kaggle", "udemy"]

    private static let allOwned: Set<String> = brands.values.reduce(into: Set<String>()) { $0.formUnion($1) }

    /// Words that make a lookalike login, payment or prize page.
    static let credentialWords: Set<String> = [
        "login", "signin", "logon", "verify", "verification", "secure", "security", "account", "accounts", "wallet", "password", "passwd", "update", "billing",
        "recover", "recovery", "helpdesk", "auth", "authenticate", "confirm", "unlock", "suspended", "alert", "support", "id", "portal", "sso", "webmail", "owa",
        "mail", "docs", "drive", "share", "meeting", "payment", "payments", "refund", "claim", "prize", "giveaway", "airdrop", "reward", "rewards", "bonus",
        "survey", "dispute", "restore", "validate", "validation", "admissions", "scholarship", "appeal", "invoice", "onboarding", "student", "students",
        "org", "com", "net", "edu", "gov",  // arxiv-org.com: the ending written as a word
    ]
    static let endingWords: Set<String> = ["org", "com", "net", "edu", "gov"]
    /// The scam half of those, for a domain with no brand in it: two of them together are a signal.
    static let scamWords: Set<String> = [
        "login", "signin", "logon", "verify", "verification", "secure", "security", "account", "wallet", "password", "update", "billing", "recover", "recovery",
        "suspended", "unlock", "confirm", "refund", "claim", "prize", "giveaway", "airdrop", "reward", "bonus", "dispute", "restore", "validate", "invoice",
        "doubler", "jackpot", "bitcoin", "crypto", "forex", "portal", "scholarship", "support", "staking", "fee", "payment", "processing", "visa", "giftcard", "free",
    ]
    static let jobWords: Set<String> = ["careers", "career", "jobs", "job", "hiring", "recruit", "recruitment", "apply", "vacancy", "vacancies", "internship", "interns", "offer"]

    // MARK: the public entry points

    /// A radar item: its address, the employer (for the apply link), and for opportunities the words of the offer.
    public static func assess(_ item: RadarItem) -> Verdict {
        let context: Context = item.kind == .internship ? .job : (RadarItem.reading.contains(item.kind) ? .article : .event)
        var fields = [item.title, item.snippet, item.eligibility ?? "", item.company ?? "", item.sponsorship ?? ""]  // not deadlineNote: robo writes "none stated" there
        fields += item.tags + item.location
        let text = fields.filter { !$0.isEmpty }.joined(separator: " ")
        let company = item.company ?? ""
        var extra: [Flag] = []
        if item.kind == .internship, let host = URLComponents(string: item.url)?.host?.lowercased() {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if !boards.contains(registrable(labels)), !institutional(labels), ownership(host: host, company: company) == .none,
               let warning = Feeds.applyWarning(for: item.url, company: company) {
                extra.append(Flag(weight: 1, reason: warning))
            }
        }
        var v = check(url: item.url, company: company, text: text, context: context, words: "", extra: extra)
        if item.kind == .paper, preprint.contains(registrable(of: v.host)), !v.warns { v.notes.append("a preprint: not peer reviewed") }
        return v
    }

    /// A link in a reply or on a card: the address and the words that showed it (empty when there are none).
    public static func assess(url: String, words: String = "") -> Verdict {
        check(url: url, company: nil, text: nil, context: .link, words: words, extra: [])
    }

    /// What the "Open this link?" alert adds under the address. Nothing for a mail address.
    public static func linkNotice(url: String, words: String = "") -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URLComponents(string: trimmed)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let v = assess(url: trimmed, words: words)
        if v.level >= .doubtful {
            let head = v.level == .scam ? "⚠ This looks like a scam." : "⚠ Be careful with this link."
            return ([head] + v.reasons.prefix(3).map { "• " + $0 }).joined(separator: "\n")
        }
        if v.level == .official { return "✓ " + capital(v.notes.first ?? "a known source") + " (" + v.host + ")." }
        var lines = v.notes.map { "• " + capital($0) + "." } + v.reasons.prefix(2).map { "• " + $0 }
        if lines.isEmpty { lines = ["Not on Robo's list of known sources. Nothing looked wrong with the address."] }
        return lines.joined(separator: "\n")
    }

    private static func capital(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// Text that came from outside, as one short plain line: control and invisible characters gone, whitespace collapsed, cut at `max`.
    static func plain(_ s: String, max: Int = 60) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: out.append(" ")
            default: out.unicodeScalars.append(u)
            }
        }
        let t = out.split(separator: " ").joined(separator: " ")
        return t.count > max ? String(t.prefix(max - 1)) + "…" : t
    }

    // MARK: the check

    struct Flag {
        var weight: Int
        var hard = false
        /// Alone it is not enough even for an offer (shouting capitals, "urgent hiring"): it needs a second signal.
        var soft = false
        var reason: String
    }

    static func check(url: String, company: String?, text: String?, context: Context, words: String, extra: [Flag]) -> Verdict {
        let stakes = context == .job || context == .event
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), let rawHost = c.host, !rawHost.isEmpty else {
            return Verdict(level: .doubtful, reasons: ["This is not a web address Robo can read."], notes: [], host: "")
        }
        var flags = extra
        var notes: [String] = []
        func flag(_ weight: Int, _ reason: String, hard: Bool = false, soft: Bool = false) { flags.append(Flag(weight: weight, hard: hard, soft: soft, reason: reason)) }

        // the host, read the way a browser would: compatibility forms folded, invisible characters and full stops of other scripts normalised
        var rawLower = trimDots(rawHost.lowercased())
        if rawLower.hasPrefix("["), rawLower.hasSuffix("]") { rawLower = String(rawLower.dropFirst().dropLast()) }  // an IPv6 address comes in brackets
        var host = rawLower.precomposedStringWithCompatibilityMapping
        for stop in ["\u{3002}", "\u{FF0E}", "\u{FF61}"] { host = host.replacingOccurrences(of: stop, with: ".") }
        host = String(String.UnicodeScalarView(host.unicodeScalars.filter { $0.properties.generalCategory != .format && $0.properties.generalCategory != .control }))
        host = trimDots(host)
        let shownHost = plain(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host, max: 80)
        if host != rawLower { flag(5, "The address is written with invisible or look-alike characters: it is not what it looks like.", hard: true) }
        let isV6 = host.contains(":")
        if !isV6, host.unicodeScalars.contains(where: { !hostScalarOK($0) }) {
            return Verdict(level: .scam, reasons: ["The address contains characters that cannot be in a web address: it hides where it goes."], notes: [], host: shownHost)
        }

        let scheme = c.scheme?.lowercased() ?? ""
        if scheme == "http" { flag(1, "The link is not encrypted (http), so what you type there can be read on the way.") }
        else if scheme != "https" { flag(5, "This link opens another app or service (\(plain(scheme, max: 20))), not a web page.", hard: true) }
        if c.user != nil || c.password != nil {
            if codeHosts.contains(host) { flag(1, "The address carries a user name.") }
            else { flag(5, "A name before an @ hides where this link really goes.", hard: true) }
        }
        if let port = c.port, port != 443, scheme == "https" || port != 80 { flag(1, "It uses an unusual port (\(port)).") }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let local = "An address on your own computer or network, not a public website."
        if isV6 {
            if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") { flag(3, local) }
            else { flag(5, "A string of numbers, not a website name.", hard: true) }
        } else if isNumeric(host) {
            if privateAddress(host) { flag(3, local) } else { flag(5, "A string of numbers, not a website name.", hard: true) }
        } else if isLocalName(host) {
            flag(3, local)
        } else if labels.count < 2 || labels.contains("") {
            flag(3, "This is not a public website address.")
        }

        let reg = registrable(labels)
        let regCount = reg.split(separator: ".").count
        let sub = Array(labels.dropLast(min(regCount, labels.count)))
        let regName = reg.split(separator: ".").first.map(String.init) ?? host
        let ending = labels.last ?? ""
        let onHosting = hosting.contains(reg)
        let institution = institutional(labels)
        if wildcardDNS.contains(reg), !sub.isEmpty { flag(5, "A number or a local name dressed up as a website name.", hard: true) }

        // look-alike letters
        var nonLatin = false
        var foldedTokens: [String] = []
        for label in labels {
            let unicode: String?
            if label.hasPrefix("xn--") {
                unicode = punycode(String(label.dropFirst(4)))
                if unicode == nil { flag(2, "The address is written in a special encoding (xn--) that can imitate another site.") }
            } else {
                unicode = label.unicodeScalars.contains { $0.value > 127 } ? label : nil
            }
            guard let u = unicode else { continue }
            let scripts = Set(u.unicodeScalars.compactMap { script($0) })
            if scripts == ["latin", "cjk"] {
                if !nonLatin { flag(1, "The address mixes Latin and East Asian letters."); nonLatin = true }
            } else if scripts.count > 1 {
                flag(5, "The address mixes alphabets (like a Cyrillic letter inside Latin text) to imitate another site.", hard: true)
            } else if scripts == ["latin"] {
                // accents and dotless letters that stand for a plain one: paypál, gıthub
                let folded = fold(u)
                if folded != u, folded.unicodeScalars.allSatisfy({ $0.isASCII }) {
                    let tokens = folded.split(separator: "-").map(String.init)
                    foldedTokens += tokens
                    if let hit = tokens.first(where: { brands[$0] != nil }) {
                        flag(5, "The address spells \(shown(hit))'s name with accented letters to imitate it.", hard: true)
                    }
                }
            } else if !scripts.isEmpty {
                if let twin = lookalike(u), isKnownName(twin) { flag(5, "Every letter of the address is a look-alike for \u{201C}\(plain(twin, max: 30))\u{201D}.", hard: true) }
                else if !nonLatin { flag(1, "The address uses non-Latin letters."); nonLatin = true }
            }
        }

        // a known name before another domain (login.microsoftonline.com.evil.xyz, arxiv.org.evil.net, mit.edu.evil.com)
        var chainFlagged = false  // (the brand rule below would say the same thing again)
        if sub.count >= 2 {
            for start in 0..<(sub.count - 1) {
                let chain = Array(sub[start...])
                let chainReg = registrable(chain)
                if allOwned.contains(chainReg) || primary.contains(chainReg) || boards.contains(chainReg) || tenants.contains(chainReg) || hosting.contains(chainReg) || institutional(chain) {
                    flag(5, "The address puts \(plain(chainReg, max: 40)) in front of another domain (\(plain(reg, max: 40))): a common trick.", hard: true)
                    chainFlagged = true
                    break
                }
            }
        }

        // a brand's name on a domain the brand does not own
        let regTokens = regName.split(separator: "-").map(String.init) + foldedTokens
        var subTokens: [String] = []
        for label in sub { subTokens += label.split(separator: "-").map(String.init) }
        let credential = (regTokens + subTokens).contains { credentialWords.contains($0) }
        let job = (regTokens + subTokens).contains { jobWords.contains($0) }
        var flaggedBrand = false
        if !institution {
            for brand in brands.keys.sorted() {
                guard let owned = brands[brand], !owns(brand: brand, owned: owned, host: host, reg: reg, ending: ending) else { continue }
                let name = shown(brand)
                // paypal.com.tk: the brand and its usual ending as two labels, then a cheap country ending
                let parts = reg.split(separator: ".").map(String.init)
                if parts.count == 3, parts[0] == brand, ["com", "org", "net", "edu", "gov"].contains(parts[1]), openEndings.contains(ending) {
                    flag(5, "The address spells \(name)'s name and its usual ending, then a cheap country ending (\(plain(reg, max: 40))).", hard: true)
                    flaggedBrand = true
                    continue
                }
                let inSub = subTokens.contains(brand)
                let inName = regTokens.contains(brand)
                // the brand stuck to a login or jobs word inside one token: paypallogin, securepaypal, appleid-support
                var rest = "", head = ""
                for token in regTokens where token != brand {
                    let after = String(token.dropFirst(brand.count)), before = String(token.dropLast(brand.count))
                    // (an ending written as a word counts as a separate part, arxiv-org, not stuck to the name: metanet is no login page)
                    if token.hasPrefix(brand), (credentialWords.contains(after) && !endingWords.contains(after)) || jobWords.contains(after) { rest = after }
                    if token.hasSuffix(brand), (credentialWords.contains(before) && !endingWords.contains(before)) || jobWords.contains(before) { head = before }
                }
                let glued = !inName && (!rest.isEmpty || !head.isEmpty)
                let inside = !inName && !glued && brand.count >= 6 && regName.replacingOccurrences(of: "-", with: "").contains(brand) && (credential || job)  // office-365-login, microsoftonline-login
                if inSub && (boards.contains(reg) || tenants.contains(reg)) {
                    // acme.zoom.us, nvidia.wd5.myworkdayjobs.com: only a login word beside the name is a signal there, or a name people steal money in
                    if credential { flag(5, "The address uses \(name)'s name with a login-style word on another service (\(plain(reg, max: 40))).", hard: true); flaggedBrand = true }
                    else if highRisk.contains(brand) { flag(3, "The address begins with \(name)'s name, but it is a page on \(plain(reg, max: 40)), not \(name)'s own."); flaggedBrand = true }
                    continue
                }
                if inSub && !onHosting && !credential && sub.contains(brand) && !highRisk.contains(brand) {
                    // microsoft.eventbuilder.com: a customer's own name before a service nobody has listed is how those services work
                    flag(3, "The address begins with \(name)'s name, but it is a page on \(plain(reg, max: 40)), not \(name)'s own.")
                } else if inSub && onHosting {
                    if credential { flag(5, "A page on a hosting service (\(plain(reg, max: 40))) using \(name)'s name with a login-style word.", hard: true) }
                    else if ["github.io", "gitlab.io"].contains(reg) { continue }  // google.github.io: GitHub gives a name to its one owner
                    else { flag(2, "A page on a hosting service (\(plain(reg, max: 40))) using \(name)'s name: anyone could have made it.") }
                } else if inSub {
                    if !chainFlagged { flag(5, "The address puts \(name)'s name in front of another domain (\(plain(reg, max: 40))): a common trick.", hard: true) }
                } else if inName || glued || inside {
                    if credential || credentialWords.contains(rest) || credentialWords.contains(head) { flag(5, "The address uses \(name)'s name with a login-style word, but \(plain(reg, max: 40)) is not \(name)'s.", hard: true) }
                    else if job || jobWords.contains(rest) || jobWords.contains(head) { flag(2, "The address uses \(name)'s name with a jobs word, but \(plain(reg, max: 40)) is not \(name)'s.") }
                    else if (regName == brand && !wordBrands.contains(brand)) || personalBrands.contains(brand) { flag(3, "\(plain(reg, max: 40)) looks like \(name)'s address, but it is not \(name)'s.") }
                    else if sourceBrands.contains(brand) { flag(2, "\(plain(reg, max: 40)) imitates the name of \(name), a source Robo knows, but it is not \(name)'s.") }
                    else { flag(1, "The domain name contains \u{201C}\(brand)\u{201D}, but \(plain(reg, max: 40)) is not \(name)'s.") }  // google.org, samsung-news.com: often the brand's own
                } else { continue }
                flaggedBrand = true
            }
            if !flaggedBrand {
                var tokens = regTokens
                if onHosting, let chosen = sub.last { tokens += chosen.split(separator: "-").map(String.init) }
                if let f = typosquat(tokens, reg: reg) { flags.append(f) }
            }
            // a lexicon of the scam (login, verify, claim, prize ...) with no brand in it
            let lexicon = Set((regTokens + subTokens).filter { scamWords.contains($0) })
            if !flaggedBrand, lexicon.count >= 2 { flag(2, "The address is made of login, verify or prize words, like a page made to catch you out.") }
        }

        if shorteners.contains(reg) || shorteners.contains(host) { flag(2, "A shortened link: you cannot see where it goes until you open it.") }
        if offPlatform.contains(reg) || offPlatform.contains(host) || formPage(host: host, path: c.path) {
            // a job that sends you to a chat or a form is a warning; for a student club's event or a plain link it is a hint
            flag(context == .job ? 2 : 1, "It sends you to a chat or form site: check who is behind it before you share anything.", soft: context != .job)
        }
        let own = context == .job ? ownership(host: host, company: company ?? "") : Ownership.none
        if riskyEndings.contains(ending), own == .none { flag(1, "Addresses ending in .\(ending) are used by scammers far more than most.") }
        if fileEndings.contains(ending) { flag(2, "An address ending in .\(ending) looks like a file name, a trick used to disguise links.") }
        // the name a visitor chose: the domain's own, or on free hosting the label before the platform
        let chosen = onHosting ? (sub.last ?? regName) : regName
        let digitsLeft = chosen.replacingOccurrences(of: #"(?:19|20)\d\d"#, with: "", options: .regularExpression).filter(\.isNumber).count
        if chosen.filter({ $0 == "-" }).count >= 3 || digitsLeft >= 6 { flag(1, "The domain name is cluttered with hyphens or digits.") }
        if onHosting, !ordinaryHosting.contains(reg) {
            flag(context == .job ? 2 : 1, "A page on a hosting service anyone can use (\(plain(reg, max: 40))): it says nothing about who made it.", soft: context == .event)
            let segments = c.path.lowercased().split(separator: "/").map { String($0.split(separator: ".").first ?? "") }
            let tight: Set<String> = ["login", "signin", "logon", "password", "unlock", "wallet", "appeal"]
            let whole: Set<String> = ["verify", "verification", "secure", "account", "confirm"]
            if segments.contains(where: { whole.contains($0) || $0.split(whereSeparator: { "-_".contains($0) }).contains(where: { tight.contains(String($0)) }) }) {
                flag(1, "The page address looks like a login or verification form.")
            }
        }
        // a known site's address written into the path: evil.example/https://arxiv.org/login, to be read at a glance as the real one
        if !(allOwned.contains(reg) || primary.contains(reg) || boards.contains(reg) || tenants.contains(reg) || proxies.contains(reg) || institution) {
            let path = String(c.path.lowercased().prefix(200))
            let ns = path as NSString
            for m in domainInPath.matches(in: path, range: NSRange(location: 0, length: ns.length)).prefix(6) {
                let named = registrable(of: ns.substring(with: m.range))
                if named != reg, allOwned.contains(named) || primary.contains(named) || boards.contains(named) {
                    flag(2, "The real address is \(plain(reg, max: 40)); the name of \(plain(named, max: 40)) only sits in the path, to be read as the real one.")
                    break
                }
            }
        }
        // edu, ac or gov as a label under a cheap country ending: a school or a government in looks only
        if labels.count >= 3, ["edu", "ac", "gov"].contains(labels[labels.count - 2]), riskyEndings.contains(ending) {
            flag(3, "The address is dressed up as a school or government address, but .\(ending) is a cheap ending anyone can register.")
        }
        if host.count > 60 || labels.count >= 6 { flag(1, "The address is unusually long or deeply nested.") }
        if let target = redirectTarget(c) ?? pathRedirect(c), !sameOwner(registrable(of: target), reg), !proxies.contains(reg) {
            flag(2, "The link passes through another address first (\(plain(registrable(of: target), max: 40))).")
        } else if redirects(c) { flag(1, "The link passes through another address first.") }

        // link text that names another site than the target
        if let shown = shownDomain(words) {
            let shownReg = registrable(of: shown)
            if !sameOwner(shownReg, reg) {
                // impersonating a name Robo knows, on an address it does not: a scam; between two names it does not know: a warning
                let known = allOwned.contains(shownReg) || primary.contains(shownReg) || boards.contains(shownReg)
                let targetKnown = allOwned.contains(reg) || primary.contains(reg) || boards.contains(reg) || institution
                flag(known && !targetKnown ? 5 : 3, "The link says \u{201C}\(plain(shown, max: 40))\u{201D} but goes to \(shownHost).", hard: known && !targetKnown)
            }
        } else if let brand = mentionedBrand(words), !owns(brand: brand, owned: brands[brand] ?? [], host: host, reg: reg, ending: ending), !institution {
            flag(3, "The link text mentions \(shown(brand)) and a sign-in, but the address is not \(shown(brand))'s.")
        }

        // the wording of an offer
        if stakes, let text, !text.isEmpty { flags += textFlags(text, context: context) }

        // good news, only for an address with nothing odd about it
        var official = flags.isEmpty
        if primary.contains(reg) { notes.append("a primary source") }
        else if institution { notes.append("a school, university or government site") }
        else if own == .brand { notes.append("the employer's own site") }
        else if own == .name { notes.append("its address matches the employer's name (that does not prove the employer is real)"); official = false }
        else if boards.contains(reg) { notes.append("a job-board platform, where anyone can post: check the employer") }
        if userWritten.contains(reg) { notes.append("written by anyone: not checked by an editor"); official = false }
        if !(primary.contains(reg) || institution || own == .brand) { official = false }

        let ordered = flags.sorted { ($0.hard ? 100 : 0) + $0.weight > ($1.hard ? 100 : 0) + $1.weight }
        let score = flags.reduce(0) { $0 + $1.weight }
        let firm = flags.contains { !$0.soft && $0.weight >= 1 }
        let level: Level
        if flags.contains(where: \.hard) { level = .scam }
        else if score >= 2 || (stakes && firm) { level = .doubtful }
        else { level = official ? .official : .ordinary }
        var seen = Set<String>()
        let reasons = ordered.map(\.reason).filter { !$0.isEmpty && seen.insert($0).inserted }
        return Verdict(level: level, reasons: Array(reasons.prefix(4)), notes: level >= .doubtful ? [] : notes, host: shownHost)
    }

    // MARK: address anatomy

    private static func trimDots(_ s: String) -> String {
        var h = s
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// Letters, digits, marks and the hyphen, dot and underscore: nothing a browser would refuse.
    private static func hostScalarOK(_ u: Unicode.Scalar) -> Bool {
        if u.isASCII { return (97...122).contains(u.value) || (48...57).contains(u.value) || u == "-" || u == "." || u == "_" }
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber: return true
        default: return false
        }
    }

    static func isNumeric(_ host: String) -> Bool {
        host.range(of: #"^(0x[0-9a-f]+|[0-9]+)(\.(0x[0-9a-f]+|[0-9]+))*$"#, options: .regularExpression) != nil
    }

    /// A dotted-decimal address inside the private ranges (and loopback, link-local).
    private static func privateAddress(_ host: String) -> Bool {
        let p = host.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 169 && p[1] == 254)
    }

    private static func isLocalName(_ host: String) -> Bool {
        host == "localhost" || [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".corp", ".intranet", ".home"].contains { host.hasSuffix($0) }
    }

    /// The domain a person can own: the last two labels, three under a country's `co.uk`-style ending, and the platform for free hosting.
    static func registrable(_ labels: [String]) -> String {
        guard labels.count > 2, let tld = labels.last else { return labels.joined(separator: ".") }
        let secondLevel: Set<String> = ["ac", "co", "com", "edu", "gov", "net", "org", "or", "ne", "go", "gob", "mil", "sch", "nom"]
        let take = tld.count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        let three = labels.suffix(3).joined(separator: ".")
        if take == 2, hosting.contains(three) { return three }  // sites.google.com
        return labels.suffix(take).joined(separator: ".")
    }

    static func registrable(of host: String) -> String {
        registrable(trimDots(host.lowercased()).split(separator: ".", omittingEmptySubsequences: false).map(String.init))
    }

    /// A school, university or government address by its ending (`.edu`, `.gov`, `.ac.uk`, `.edu.au`); not under a cheap or open country ending.
    private static func institutional(_ labels: [String]) -> Bool {
        guard let end = labels.last, labels.count >= 2 else { return false }
        if ["edu", "gov", "mil", "int"].contains(end) { return true }
        let second = labels[labels.count - 2]
        // edu.co, gov.ly and ac.uk are kept for the institutions they name; the free endings (tk, ml, ga, cf, gq, cc, ws...) hand out any name
        return end.count == 2 && ["edu", "gov", "ac"].contains(second) && !riskyEndings.contains(end) && !["to", "tv", "me", "vu", "nu"].contains(end)
    }

    /// Registers its name under every ending, the cheap ones included (google.com.ly, google.ws): there a look-alike cannot be told from the real one.
    private static let everyEnding: Set<String> = ["google"]

    private static func owns(brand: String, owned: Set<String>, host: String, reg: String, ending: String) -> Bool {
        if owned.contains(reg) || host.hasSuffix("." + brand) || host == brand { return true }
        if owned.contains(ending + ".com") { return true }  // a company's own top-level domain: anything.google, anything.amazon
        if everyEnding.contains(brand), reg.split(separator: ".").first.map(String.init) == brand, ending.count == 2 { return true }
        // the brand's own name with a country's ending (google.ae, amazon.de, amazon.com.br, google.com.co)
        let parts = reg.split(separator: ".").map(String.init)
        guard parts.first == brand, ending.count == 2, !personalBrands.contains(brand) else { return false }
        return !openEndings.contains(ending) || (ending == "co" && parts.count == 3 && parts[1] == "com" && everyEnding.contains(brand))
    }

    private static func formPage(host: String, path: String) -> Bool {
        (host == "docs.google.com" && path.hasPrefix("/forms")) || ((host == "discord.com" || host == "discordapp.com") && path.hasPrefix("/invite"))
            || (host.hasSuffix("whatsapp.com") && (path.hasPrefix("/channel") || path.hasPrefix("/send")))
    }

    /// Where a known site's name in the PATH is no proof of anything (a web archive and a reader keep the address they copied).
    private static let proxies: Set<String> = ["archive.org", "archive.ph", "archive.is", "jina.ai", "12ft.io", "translate.goog"]
    private static let domainInPath = try! NSRegularExpression(pattern: #"(?:[a-z0-9-]+\.)+[a-z]{2,}"#)

    private static let redirectKeys = "url|u|uri|redirect|redirect_uri|redirect_url|target|dest|destination|next|link|goto|return|returnurl|return_to|continue|to|r|q|out|forward|callback|href|ref"

    /// The address a link passes through to, from its query: `?url=https://...`, `?q=https%3A%2F%2F...` (decoded twice).
    static func redirectTarget(_ c: URLComponents) -> String? {
        for item in c.queryItems ?? [] where item.value != nil {
            guard item.name.range(of: "^(?:\(redirectKeys))$", options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            var value = item.value ?? ""
            if value.hasPrefix("%") || value.lowercased().hasPrefix("https%3a") || value.lowercased().hasPrefix("http%3a") { value = value.removingPercentEncoding ?? value }
            if let t = URLComponents(string: value), let h = t.host, t.scheme?.lowercased().hasPrefix("http") == true { return h.lowercased() }
            if value.hasPrefix("//"), let t = URLComponents(string: "https:" + value), let h = t.host { return h.lowercased() }
        }
        return nil
    }

    private static let pathRedirectPattern = try! NSRegularExpression(pattern: #"(?:^|/)(?:https?:/+|amp/s/)([a-z0-9-]+(?:\.[a-z0-9-]+)+)"#)

    /// google.com/amp/s/evil.example, example.org/https://evil.example: the address the path hands you on to.
    static func pathRedirect(_ c: URLComponents) -> String? {
        let path = String(c.path.lowercased().prefix(300))
        let ns = path as NSString
        guard let m = pathRedirectPattern.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func redirects(_ c: URLComponents) -> Bool {
        let q = (c.percentEncodedQuery ?? "").lowercased()
        return q.range(of: "(?:^|&)(?:\(redirectKeys))=(?:https?(?:%3a|:)|%2f%2f|//)", options: .regularExpression) != nil
    }

    // MARK: link words

    private static let bareHost = try! NSRegularExpression(pattern: #"^(?:https?://)?(?:www\.)?([a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)+)(?::\d+)?(?:[/?#]\S*)?$"#)
    private static let genericEndings: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int", "info", "biz", "app", "dev", "xyz", "online", "site", "tech", "store", "shop", "club", "live", "link",
        "top", "blog", "cloud", "ai", "io", "me", "tv", "cc", "co", "ly", "gg", "fm", "sh", "so", "to",
    ]
    private static let codeEndings: Set<String> = ["py", "md", "js", "rs", "pl", "ts", "rb", "cs", "kt", "go", "txt", "pdf", "png", "jpg", "csv", "json", "html", "css", "zip", "doc", "docx"]

    /// The address the link's words show, when the words are nothing but an address ("arxiv.org/abs/1", "https://www.nus.edu.sg"); nil
    /// for any sentence. Only the first 300 characters are read, so a huge text costs the same as a long one.
    static func shownDomain(_ words: String) -> String? {
        var w = String(words.prefix(300)).precomposedStringWithCompatibilityMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for (a, b) in [("[.]", "."), ("(.)", "."), ("\u{3002}", "."), (" . ", ".")] { w = w.replacingOccurrences(of: a, with: b) }
        let ns = w as NSString
        guard let m = bareHost.firstMatch(in: w, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        let host = ns.substring(with: m.range(at: 1))
        guard let end = host.split(separator: ".").last.map(String.init), end.allSatisfy(\.isLetter), !codeEndings.contains(end),
              genericEndings.contains(end) || end.count == 2 else { return nil }
        return host
    }

    private static func sameOwner(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // a DOI resolver leads to a publisher: it is the same as one, not as any address at all
        if resolvers.contains(a) || resolvers.contains(b) {
            let other = resolvers.contains(a) ? b : a
            return resolvers.contains(other) || primary.contains(other) || institutional(other.split(separator: ".").map(String.init))
        }
        if aliasGroups.contains(where: { $0.contains(a) && $0.contains(b) }) { return true }
        if brands.values.contains(where: { $0.contains(a) && $0.contains(b) }) { return true }
        // the same name under two ordinary endings (bbc.com and bbc.co.uk): not under a cheap one (paypal.com and paypal.tk)
        let pa = a.split(separator: ".").map(String.init), pb = b.split(separator: ".").map(String.init)
        guard let la = pa.first, la == pb.first, la.count >= 3, let ea = pa.last, let eb = pb.last else { return false }
        return ![ea, eb].contains { openEndings.contains($0) || riskyEndings.contains($0) }
    }

    private static let signInWords = try! NSRegularExpression(pattern: #"\b(?:sign ?in|log ?in|verify|password|account|confirm|secure|reset|update your)\b"#)

    /// A brand named in the link's words next to a sign-in word ("Sign in to your Microsoft account").
    static func mentionedBrand(_ words: String) -> String? {
        let w = String(words.prefix(300)).precomposedStringWithCompatibilityMapping.lowercased()
        let ns = w as NSString
        guard signInWords.firstMatch(in: w, range: NSRange(location: 0, length: ns.length)) != nil else { return nil }
        for brand in brands.keys.sorted() where brand.count >= 4 {
            if w.range(of: "\\b\(brand)\\b", options: .regularExpression) != nil { return brand }
        }
        return nil
    }

    // MARK: the employer

    enum Ownership { case none, name, brand }

    /// How a listing's address relates to its company. `brand`: a domain the brand list gives that company (lifeattiktok.com for TikTok).
    /// `name`: the address looks like the company's name, which proves nothing (the company comes from the same feed as the address).
    /// A job board, a tenant service or free hosting is never either.
    static func ownership(host: String, company: String) -> Ownership {
        let reg = registrable(of: host)
        if company.isEmpty || boards.contains(reg) || tenants.contains(reg) || hosting.contains(reg) || userWritten.contains(reg) { return .none }
        let words = company.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains(where: { brands[$0]?.contains(reg) == true }) { return .brand }
        if Feeds.applyWarning(for: "https://" + host + "/", company: company) == nil { return .name }
        let labels = reg.split(separator: ".").map(String.init)
        return nameMatches(labels.first ?? "", ending: labels.last ?? "", words: words) ? .name : .none
    }

    private static let legalWords: Set<String> = ["inc", "llc", "ltd", "corp", "corporation", "co", "company", "companies", "group", "the", "gmbh", "ag", "plc", "sa", "bv", "limited"]
    private static let corporateSuffixes: Set<String> = [
        "inc", "corp", "co", "hq", "llc", "ltd", "group", "capital", "med", "medical", "labs", "lab", "holdings", "energy", "systems", "tech", "technologies",
        "international", "global", "europe", "usa", "asia", "intl", "research", "ri",
    ]

    /// A domain name that is a recognisable form of the company's name: the name itself with the hyphens gone, a shorter form of it
    /// (towerresearch for Tower Research Capital), its initials (itw for Illinois Tool Works), a company's own ending (careers.cern), or its
    /// name or first word plus a corporate ending (datadoghq, clydeinc, murumed). Not just any prefix, and not jobs/careers words:
    /// `stripe-jobs.xyz` must not pass for Stripe.
    static func nameMatches(_ label: String, ending: String, words all: [String]) -> Bool {
        let words = all.filter { !legalWords.contains($0) }
        let l = label.replacingOccurrences(of: "-", with: "")
        guard !words.isEmpty else { return false }
        let joined = words.joined()
        if ending.count >= 3, ending == joined { return true }  // careers.cern
        if (l + ending) == joined { return true }  // x.ai for xAI
        guard l.count >= 3 else { return false }
        if l == joined { return true }
        if l.count >= 5, joined.hasPrefix(l) { return true }
        if words.count >= 3, String(words.compactMap(\.first)) == l { return true }
        if l.hasPrefix("lifeat"), String(l.dropFirst(6)) == joined { return true }
        for prefix in [joined, words[0]] where prefix.count >= 3 && l.hasPrefix(prefix) {
            let rest = String(l.dropFirst(prefix.count))
            // a three-letter name (bmw) is only matched by a plain corporate ending, a longer one by any
            if corporateSuffixes.contains(rest), prefix.count >= 4 || ["group", "inc", "corp", "hq", "holdings", "global", "international"].contains(rest) { return true }
        }
        return false
    }

    // MARK: letters

    static func script(_ u: Unicode.Scalar) -> String? {
        guard u.properties.isAlphabetic else { return nil }
        switch u.value {
        case 0x41...0x5A, 0x61...0x7A, 0xB5, 0xC0...0x2AF, 0x1D00...0x1DBF, 0x1E00...0x1EFF: return "latin"
        case 0x370...0x3FF, 0x1F00...0x1FFF: return "greek"
        case 0x400...0x52F: return "cyrillic"
        case 0x530...0x58F: return "armenian"
        case 0x590...0x5FF: return "hebrew"
        case 0x600...0x6FF, 0x750...0x77F: return "arabic"
        case 0x3040...0x30FF, 0x4E00...0x9FFF, 0xAC00...0xD7AF: return "cjk"
        default: return "other"
        }
    }

    private static let confusables: [Character: Character] = [
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "х": "x", "у": "y", "і": "i", "ѕ": "s", "ј": "j", "ӏ": "l", "һ": "h", "ԁ": "d", "ԛ": "q", "ԝ": "w",
        "ο": "o", "α": "a", "ν": "v", "ι": "i", "ρ": "p", "τ": "t", "κ": "k", "υ": "u", "ɡ": "g", "ɑ": "a",
    ]

    /// The label with every look-alike letter written as its Latin twin, or nil when a letter has none (a real word in that language).
    static func lookalike(_ label: String) -> String? {
        var out = ""
        for ch in label {
            if ch.isASCII { out.append(ch) } else if let l = confusables[ch] { out.append(l) } else { return nil }
        }
        return out
    }

    /// A look-alike spelling that stands for a brand, a source or a host Robo knows (so a real Russian word spelled in look-alikes is not one).
    private static func isKnownName(_ twin: String) -> Bool {
        let tokens = twin.split(separator: "-").map(String.init)
        return tokens.contains { brands[$0] != nil } || primary.contains { $0.hasPrefix(twin + ".") } || boards.contains { $0.hasPrefix(twin + ".") }
    }

    /// Accents and dotless letters written as the plain letter they imitate (paypál -> paypal, gıthub -> github).
    static func fold(_ s: String) -> String {
        var out = ""
        for u in s.decomposedStringWithCanonicalMapping.unicodeScalars where u.properties.generalCategory != .nonspacingMark {
            switch u {
            case "ı": out.append("i")
            case "ø": out.append("o")
            case "ł": out.append("l")
            case "đ", "ð": out.append("d")
            case "ß": out.append("ss")
            case "æ": out.append("ae")
            case "œ": out.append("oe")
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    // MARK: a brand with one letter changed

    /// `paypa1`, `g00gle`, `rnicrosoft` (a digit or `rn` for the letter it imitates), and `paypall` / `micosoft` (one letter off a name of six or more).
    static func typosquat(_ tokens: [String], reg: String = "") -> Flag? {
        if allOwned.contains(reg) { return nil }  // a domain some brand really owns (hicloud.com, tiktokv.com) is no typo of another
        for token in Set(tokens).sorted() where token.count >= 4 {
            let swaps = skeletons(token)
            for brand in brands.keys.sorted() where brand.count >= 4 && token != brand {
                if swaps.contains(brand) && (token.contains(where: \.isNumber) || token.contains("rn") || token.contains("vv")) {
                    return Flag(weight: 5, hard: true, reason: "The address imitates \(shown(brand))'s name (\u{201C}\(plain(token, max: 30))\u{201D}).")
                }
                // one letter off a name of six or more (paypall, gooogle): not iCloud's, whose neighbours (pcloud, qcloud) are real services
                if brand.count >= 6, !wordBrands.contains(brand), brand != "icloud", token.count >= 6, oneEdit(token, brand) {
                    return Flag(weight: 2, reason: "The address is one letter away from \(shown(brand))'s name (\u{201C}\(plain(token, max: 30))\u{201D}).")
                }
            }
        }
        return nil
    }

    private static func skeletons(_ token: String) -> Set<String> {
        var out: Set<String> = [token]
        let table: [(Character, [Character])] = [("0", ["o"]), ("1", ["l", "i"]), ("3", ["e"]), ("5", ["s"]), ("4", ["a"]), ("7", ["t"]), ("8", ["b"])]
        for (digit, letters) in table where token.contains(digit) {
            let before = out
            for l in letters { out.formUnion(before.map { $0.replacingOccurrences(of: String(digit), with: String(l)) }) }
        }
        out.formUnion(out.map { $0.replacingOccurrences(of: "rn", with: "m").replacingOccurrences(of: "vv", with: "w") })
        return out
    }

    /// Exactly one letter inserted, removed or changed (or two neighbours swapped).
    static func oneEdit(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        guard abs(x.count - y.count) <= 1, x != y else { return false }
        if x.count == y.count {
            let diff = (0..<x.count).filter { x[$0] != y[$0] }
            if diff.count == 1 { return true }
            return diff.count == 2 && diff[1] == diff[0] + 1 && x[diff[0]] == y[diff[1]] && x[diff[1]] == y[diff[0]]
        }
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        var i = 0
        while i < short.count && long[i] == short[i] { i += 1 }
        return Array(long[(i + 1)...]) == Array(short[i...])
    }

    // MARK: punycode (RFC 3492)

    /// The text of a label after `xn--`; nil when it is not valid punycode.
    static func punycode(_ s: String) -> String? {
        let bytes = Array(s.utf8)
        guard bytes.allSatisfy({ $0 < 128 }), bytes.count <= 63 else { return nil }
        var out: [UInt32] = []
        var pos = 0
        if let d = bytes.lastIndex(of: UInt8(ascii: "-")) {
            out = bytes[..<d].map { UInt32($0) }
            pos = d + 1
        }
        var n: UInt32 = 128, i: UInt32 = 0, bias: UInt32 = 72
        while pos < bytes.count {
            let oldi = i
            var w: UInt32 = 1, k: UInt32 = 36
            while true {
                guard pos < bytes.count else { return nil }
                let c = bytes[pos]
                pos += 1
                let digit: UInt32
                switch c {
                case 48...57: digit = UInt32(c) - 22
                case 65...90: digit = UInt32(c) - 65
                case 97...122: digit = UInt32(c) - 97
                default: return nil
                }
                let (dw, o1) = digit.multipliedReportingOverflow(by: w)
                let (ni, o2) = i.addingReportingOverflow(dw)
                if o1 || o2 { return nil }
                i = ni
                let t: UInt32 = k <= bias ? 1 : (k >= bias + 26 ? 26 : k - bias)
                if digit < t { break }
                let (nw, o3) = w.multipliedReportingOverflow(by: 36 - t)
                if o3 { return nil }
                w = nw
                k += 36
            }
            let count = UInt32(out.count + 1)
            bias = adapt(i - oldi, count, first: oldi == 0)
            let (nn, o4) = n.addingReportingOverflow(i / count)
            if o4 { return nil }
            n = nn
            i %= count
            guard Unicode.Scalar(n) != nil else { return nil }
            out.insert(n, at: Int(i))
            i += 1
        }
        var view = String.UnicodeScalarView()
        for c in out {
            guard let u = Unicode.Scalar(c) else { return nil }
            view.append(u)
        }
        return String(view)
    }

    private static func adapt(_ delta: UInt32, _ points: UInt32, first: Bool) -> UInt32 {
        var d = first ? delta / 700 : delta / 2
        d += d / points
        var k: UInt32 = 0
        while d > 455 {
            d /= 35
            k += 36
        }
        return k + (36 * d) / (d + 38)
    }

    // MARK: the wording of an offer

    /// One pattern, how heavy it is in a job offer and in an event (contest, hackathon, programme) (5 = a scam, 0 = not looked for there),
    /// whether it is only a hint (`soft`), and how a denial is recognised. `loose` also takes "no" and "zero" as a denial (the fee rules:
    /// "no application fee"); `inside` also looks for a denial inside the match ("we interview via Zoom, never via WhatsApp"); `unless` is
    /// a pattern that, near the match, turns it into the opposite ("the visa fee is covered").
    private struct Rule {
        enum Denial { case strict, loose, conditional }
        let pattern: String
        let job: Int
        let event: Int
        var soft = false
        /// What cancels a match when it is just before it: `strict` "never", "not", "don't"; `loose` also a bare "no" or "zero" (the fee rules);
        /// `conditional` also "if", "when", "once", "after" ("if you have been selected").
        var denial = Denial.strict
        var inside = false
        var unless: String?
        let reason: String
    }

    private static let sendVerbs = #"(?:send|provide|submit|share|upload|email|text|attach|include|forward|give|enter|fill in|reply with|confirm|verify)"#
    private static let rules: [Rule] = [
        Rule(pattern: "\\b\(sendVerbs)\\b[^.;]{0,40}\\b(?:bank (?:account|details|info|information|statement)|account number|iban|routing number|credit card|debit card|card number|cvv|pin number|ssn|social security|seed phrase|recovery phrase|private key)\\b",
             job: 5, event: 3, inside: true, reason: "The offer asks for your bank or card details. A real employer never needs these to apply."),
        Rule(pattern: "\\b\(sendVerbs)\\b[^.;]{0,40}\\b(?:passport|national id|id card|identity card|driving licen[cs]e|emirates id|aadhaar|pan card|utility bill)\\b",
             job: 3, event: 0, inside: true,
             unless: #"\b(?:after|once|upon|following)\b[^.;]{0,30}\b(?:offer|accept\w*|hired|contract|onboarding|appointment)\b|\bvisa\b|\binvitation letter\b|\bbackground check\b|\bidentity verification\b|\bright[- ]to[- ]work\b|\bi-?9\b"#,
             reason: "The offer asks for a copy of your ID early. Do it only once you are sure the employer is real."),
        Rule(pattern: #"\b(?:buy|purchase|send|pay(?:ing)?|paid|redeem|scratch|photo of|picture of)\b[^.;]{0,30}\bgift[- ]?cards?\b|\bgift[- ]?cards?\b[^.;]{0,30}\b(?:codes?|numbers?|pins?|photos?|pictures?)\b|\b(?:itunes|apple|google play|steam) cards?\b[^.;]{0,20}\b(?:buy|send|worth|codes?)\b"#,
             job: 5, event: 3, inside: true, reason: "The offer asks you to buy or send gift cards, the usual way scam money moves."),
        Rule(pattern: #"\b(?:send|wire|pay|transfer|deposit)\b[^.;]{0,30}\b(?:western union|moneygram|money order|cashier'?s? che(?:ck|que)|zelle|cash ?app|venmo|bitcoin atm)\b|\b(?:western union|moneygram)\b[^.;]{0,30}\b(?:payment|fee|transfer|required|only)\b|\b(?:send|pay|transfer)\b[^.;]{0,25}\b(?:money|fee|deposit|payment)\b[^.;]{0,25}\b(?:wire transfer|bank transfer)\b"#,
             job: 5, event: 3, inside: true, reason: "The offer asks for money through a channel that cannot be traced or undone."),
        Rule(pattern: #"\b(?:whatsapp|telegram)\b[^.;]{0,40}\b(?:interview|hiring|recruit\w*|apply|application|hr|manager)\b|\b(?:interview|hiring|recruit\w*|apply|application|contact|message|text|add|reach)\b[^.;]{0,40}\b(?:on|via|through|by|using|over)\s+(?:whatsapp|telegram)\b|\b(?:whatsapp|telegram)\b[^.;]{0,30}\+?\d[\d\s-]{7,}"#,
             job: 5, event: 0, inside: true, reason: "The offer moves the interview or the application to WhatsApp or Telegram, a common job-scam step."),
        Rule(pattern: #"\b(?:wechat|zalo|viber|kakao ?talk|skype)\b[^.;]{0,40}\b(?:interview|hiring|recruit\w*|apply|application)\b|\b(?:interview|hiring|recruit\w*|apply|application)\b[^.;]{0,40}\b(?:on|via|through|by|using|over)\s+(?:wechat|zalo|viber|kakao ?talk|skype)\b|واتساب|تيليجرام|微信"#,
             job: 2, event: 0, inside: true, reason: "The offer moves the interview or the application to a chat app. Check it on the employer's own site."),
        Rule(pattern: #"\bguaranteed\b[^.;]{0,20}\b(?:job|income|salary|returns?|profit|payout|visa|employment|pay)\b|\b(?:assured|sure-?shot)\s+(?:job|placement|offer|income)\b|\b100%\s+(?:placement|job)\s+(?:guarantee|assured)\b|\bno interview (?:needed|required|necessary)\b|\binstant (?:offer|hiring|job)\b"#,
             job: 5, event: 2, reason: "The offer guarantees a job or income, or skips the interview. Nobody honest can."),
        Rule(pattern: #"\b(?:no|zero)\s+(?:experience|skills?|qualifications?)\b[^.;]{0,60}(?:\$|€|£|usd|aed)\s?\d{3,}[^.;]{0,25}(?:per|/|an?|every)\s?(?:hour|hr|day)\b|\b(?:earn|make|income of)\s+(?:up to\s+)?(?:\$|€|£|usd|aed)\s?\d[\d,]{2,}\s*(?:per|a|/|every)?\s*(?:day|daily|week|weekly)\b"#,
             job: 5, event: 0, reason: "The offer promises high daily pay for no experience."),
        // YOU pay: "you must pay for your own training", or an order ("Pay for your starter kit"); not "we pay for your equipment"
        Rule(pattern: #"\b(?:you|applicants?|candidates?|interns?)(?:\s+(?:only|just|simply|must|need to|will|have to|are required to|should|can|to))*\s+(?:pay|buy|purchase)\b[^.;]{0,40}\b(?:training|equipment|laptop|software|background check|starter kit|kit)\b|(?:^|[.;:,!?]\s*|\bplease\s+)(?:pay|buy|purchase)\b[^.;]{0,30}\b(?:your own|for your)\b[^.;]{0,20}\b(?:training|equipment|laptop|software|background check|starter kit|kit)\b"#,
             job: 5, event: 0, reason: "The offer makes you pay for equipment or training before you start."),
        Rule(pattern: #"\b(?:crypto(?:currency)?|bitcoin|usdt|ethereum)\b[^.;]{0,30}\bdeposit\b|\bdeposit\b[^.;]{0,30}\b(?:crypto|bitcoin|usdt|ethereum)\b"#,
             job: 5, event: 0, reason: "The offer involves a crypto deposit."),
        Rule(pattern: #"\b(?:crypto(?:currency)?|bitcoin|usdt|ethereum)\b[^.;]{0,30}\b(?:wallet|payment|payout|trading|invest(?:ment)?)\b"#,
             job: 1, event: 0, soft: true, reason: "The offer is about crypto: check who is behind it."),
        Rule(pattern: #"\b(?:visa|offer|contract|clearance|onboarding|work permit)\s+(?:processing\s+)?(?:fees?|charges?)\b"#,
             job: 5, event: 0, inside: true, unless: #"\b(?:covered|covers?|reimburs\w*|waived|waives?|included|includes?|sponsor\w*|free|paid by|(?:company|employer|we|us)\s+(?:will\s+)?pays?)\b"#,
             reason: "The offer asks for a fee to process your visa, contract or onboarding."),
        Rule(pattern: #"\binvest\b[^.;]{0,30}\b(?:bitcoin|crypto(?:currency)?|usdt|forex)\b|\b(?:bitcoin|crypto(?:currency)?|forex)\b[^.;]{0,30}\b(?:start earning|double your|guaranteed returns?)\b"#,
             job: 5, event: 0, reason: "The offer asks you to put money into crypto or forex."),
        Rule(pattern: #"\b(?:registration|application|processing|training|admin|onboarding|activation|security|enrol?ment|course|certification|courier|sponsorship|permit|verification|clearance)\s+(?:fees?|charges?|deposits?)\b|\b(?:fees?|charges?)\s+(?:is |are )?(?:payable|required|due)\b"#,
             job: 2, event: 2, denial: .loose, unless: #"\b(?:free|none|nil|waived|waiver|\$0|n/a|refund\w*|covered)\b"#,
             reason: "The offer mentions a fee. Never pay to be hired; some contests and programmes do charge to enter, so check on their own site."),
        Rule(pattern: "\\b\(sendVerbs)\\b[^.;]{0,40}\\b(?:social insurance|id proof|proof of id|selfie (?:holding|with) (?:your )?id)\\b",
             job: 5, event: 0, inside: true, reason: "The offer asks for ID numbers or a selfie with your ID. A real employer never needs these to apply."),
        Rule(pattern: #"\bpay\b[^.;]{0,15}\bby\s+(?:wire|bank) transfer\b"#, job: 5, event: 3, inside: true,
             reason: "The offer asks for money through a channel that cannot be traced or undone."),
        Rule(pattern: #"\b(?:job|placement|offer)\s+(?:is\s+)?(?:assured|guaranteed)\b|\bno interview\b[^.;]{0,20}\bno experience\b|\bno experience\b[^.;]{0,20}\bno interview\b"#,
             job: 5, event: 2, reason: "The offer guarantees a job or skips the interview and the experience. Nobody honest can."),
        Rule(pattern: #"\b(?:simple|easy)\s+(?:online\s+)?tasks?\b[^.;]{0,40}\b(?:paid|earn|daily|per)\b|\bget paid daily\b|\brate products\b|\bboost (?:app )?rankings?\b"#,
             job: 5, event: 0, reason: "The offer describes a task or rating scam: paid daily for simple online tasks."),
        Rule(pattern: #"\b(?:pay|paying|payment|charge|fee|tax|clearance|customs)\b[^.;]{0,40}\b(?:to release|to receive|to claim|to collect|before (?:you|we) (?:can )?(?:release|send|receive))\b[^.;]{0,20}\b(?:prize|winnings|funds|reward|money)\b|\b(?:shipping and handling|handling|customs|clearance)\b[^.;]{0,30}\b(?:charge|fee)\b[^.;]{0,40}\b(?:release|receive|claim)\b[^.;]{0,20}\b(?:prize|winnings|funds|reward)\b|\bpay (?:the )?tax first\b"#,
             job: 5, event: 5, inside: true, reason: "The prize has to be paid for before it is released. A real prize never is."),
        Rule(pattern: #"\b(?:connect|link)\b[^.;]{0,20}\bwallet\b[^.;]{0,40}\b(?:claim|prize|approve|verify|reward)\b|\bapprove the transaction\b"#,
             job: 5, event: 3, reason: "The offer asks you to connect your crypto wallet and approve a transaction, the way wallets are drained."),
        Rule(pattern: #"\b(?:mail|send|give)\b[^.;]{0,20}\b(?:check|cheque)\b[^.;]{0,40}\b(?:purchase|buy|pay for)\b[^.;]{0,30}\b(?:equipment|laptop|supplies|software)\b"#,
             job: 5, event: 0, reason: "The offer sends you a check to buy equipment: the fake-check scam."),
        Rule(pattern: #"\b(?:salary|stipend|paid|pay)\b[^.;]{0,30}\b(?:in|via|with)\s+(?:usdt|bitcoin|btc|crypto)\b"#,
             job: 2, event: 0, reason: "The offer pays in crypto: check who is behind it."),
        Rule(pattern: #"\b(?:refundable\s+)?(?:deposit|payment|fee)\b[^.;]{0,25}\b(?:secures?|confirms?|reserves?|holds?)\b[^.;]{0,15}\b(?:seat|place|spot|position)\b|\bpay\b[^.;]{0,20}\b(?:token|small)\s+(?:amount|fee|deposit)\b"#,
             job: 3, event: 2, reason: "The offer asks for money to hold your place."),
        Rule(pattern: #"\b(?:certification|course|training)\b[^.;]{0,30}\$\s?\d+[^.;]{0,30}\bbefore\b[^.;]{0,15}\b(?:onboarding|starting|start|joining)\b"#,
             job: 5, event: 0, reason: "The offer asks you to pay for a course or certificate before you start."),
        Rule(pattern: #"\b(?:hr|recruit\w*|careers?|jobs?|hiring)[\w.-]*@(?:gmail|yahoo|outlook|hotmail|proton|protonmail|aol|mail)\.\w+"#,
             job: 5, event: 0, reason: "The recruiter writes from a free mail address, not the employer's own."),
        Rule(pattern: #"\bwhatsapp only\b|\(whatsapp\)"#, job: 5, event: 0, reason: "The offer is answered on WhatsApp only, a common job-scam step."),
        Rule(pattern: #"\b(?:on|via|through|using)\s+signal\b(?!\s+(?:processing|analysis|detection|noise|data|quality|strength))"#, job: 2, event: 0,
             reason: "The offer moves the conversation to a chat app. Check it on the employer's own site."),
        Rule(pattern: #"\burgent(?:ly)? hiring\b"#, job: 1, event: 1, soft: true, reason: "The offer says it is hiring urgently, a pressure tactic."),
        Rule(pattern: #"\bact now\b|\bhurry\b|\bexpires? in \d+ (?:hours?|minutes?)\b|\bonly \d+ (?:spots?|seats?|slots?) left\b|\bor lose your (?:seat|place|spot)\b|\bbefore midnight\b"#,
             job: 1, event: 1, soft: true, reason: "The offer pushes you to hurry, a pressure tactic."),
        Rule(pattern: #"\byou(?:'ve| have)? been (?:selected|shortlisted|chosen|picked|awarded|granted)\b|\bcongratulations\b[^.]{0,30}\b(?:selected|won|winner|chosen)\b"#,
             job: 2, event: 2, denial: .conditional, reason: "The offer says you were already selected, before you applied."),
        Rule(pattern: #"\b100% (?:guaranteed|legit|genuine)\b"#,
             job: 1, event: 1, soft: true, reason: "The offer swears it is genuine, exaggerated claims."),
        Rule(pattern: #"!{3,}"#, job: 1, event: 1, soft: true, reason: "The offer shouts: exaggerated claims."),
    ]
    private static let compiled: [(Rule, NSRegularExpression)] = rules.compactMap { r in (try? NSRegularExpression(pattern: r.pattern, options: .caseInsensitive)).map { (r, $0) } }
    private static let unlessCache: [String: NSRegularExpression] = rules.reduce(into: [:]) { out, r in if let u = r.unless, let re = try? NSRegularExpression(pattern: u, options: .caseInsensitive) { out[u] = re } }
    /// A denial: "never", "not", "don't", "without", "nobody"... (a bare "no" is not one: "No experience needed, send your passport" is a scam).
    private static let strictNegators = try! NSRegularExpression(pattern: #"\b(?:never|not|nobody|no one|without(?!\s+further)|cannot|do not|will not)\b|n't\b"#, options: .caseInsensitive)
    private static let looseNegators = try! NSRegularExpression(pattern: #"\b(?:never|not|nobody|no one|without(?!\s+further)|cannot|do not|will not|no|zero|free of|neither|nor)\b|n't\b"#, options: .caseInsensitive)
    private static let conditionalNegators = try! NSRegularExpression(pattern: #"\b(?:never|not|nobody|no one|without(?!\s+further)|cannot|do not|will not|if|when|once|after|whether|until|should)\b|n't\b"#, options: .caseInsensitive)

    /// The text as the rules should read it: compatibility forms folded (fullwidth letters), accents and combining marks dropped, look-alike
    /// letters of other scripts written as Latin, curly apostrophes straightened.
    static func normalisedText(_ s: String) -> String {
        var out = ""
        for u in s.decomposedStringWithCompatibilityMapping.unicodeScalars where u.properties.generalCategory != .nonspacingMark {
            switch u {
            case "\u{2019}", "\u{2018}", "\u{02BC}": out.append("'")
            default:
                if let l = confusables[Character(u)] { out.append(l) } else { out.unicodeScalars.append(u) }
            }
        }
        // letters spaced out ("W h a t s A p p") are joined; @, 0 and 1 between letters are the letters they stand for ("p@ssport", "g1ft")
        let ns = out as NSString
        var joined = "", last = 0
        for m in spacedLetters.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            joined += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + ns.substring(with: m.range).replacingOccurrences(of: " ", with: "")
            last = m.range.location + m.range.length
        }
        joined += ns.substring(from: last)
        // an e-mail address keeps its @ (the free-mail rule reads it); everything else is un-spelled
        let jns = joined as NSString
        var result = "", from = 0
        func unspell(_ part: String) -> String {
            var p = part
            for (pattern, letter) in [("(?<=[A-Za-z])@(?=[A-Za-z])", "a"), ("(?<=[A-Za-z])0(?=[A-Za-z])", "o"), ("(?<=[A-Za-z])1(?=[A-Za-z])", "i")] {
                p = p.replacingOccurrences(of: pattern, with: letter, options: .regularExpression)
            }
            return p
        }
        for m in emailAddress.matches(in: joined, range: NSRange(location: 0, length: jns.length)) {
            result += unspell(jns.substring(with: NSRange(location: from, length: m.range.location - from))) + jns.substring(with: m.range)
            from = m.range.location + m.range.length
        }
        result += unspell(jns.substring(from: from))
        return result
    }
    private static let spacedLetters = try! NSRegularExpression(pattern: #"\b(?:[A-Za-z] ){3,}[A-Za-z]\b"#)
    private static let emailAddress = try! NSRegularExpression(pattern: #"[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#)

    /// What follows the last full stop, comma, colon or dash: a denial in an earlier clause ("No experience needed - send ...", "Do not
    /// delay: send ...") says nothing about this one.
    private static func clauseTail(_ s: String) -> String {
        var t = s
        if let cut = t.lastIndex(where: { ".!?;,:\u{2014}\u{2013}".contains($0) }) { t = String(t[t.index(after: cut)...]) }
        if let r = t.range(of: " - ", options: .backwards) { t = String(t[r.upperBound...]) }
        return t
    }

    /// The flags of the wording of an offer. A statement that denies it ("we will never ask for your passport", "no application fee") does
    /// not count: the 45 characters before a match, back to the start of its clause, are read for a denial.
    static func textFlags(_ raw: String, context: Context) -> [Flag] {
        let t = normalisedText(String(raw.prefix(2_000)))
        let ns = t as NSString
        var out: [Flag] = []
        for (rule, re) in compiled {
            let weight = context == .job ? rule.job : rule.event
            guard weight > 0 else { continue }
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let start = max(0, m.range.location - 45)
                let before = clauseTail(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
                let negators: NSRegularExpression
                switch rule.denial {
                case .strict: negators = strictNegators
                case .loose: negators = looseNegators
                case .conditional: negators = conditionalNegators
                }
                func denied(_ s: String) -> Bool { negators.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }
                if denied(before) { continue }
                let matched = ns.substring(with: m.range)
                if rule.inside, denied(matched) { continue }
                if let u = rule.unless, let ure = unlessCache[u] {
                    // the words that turn it round ("the visa fee is covered") must be in its own sentence
                    let end = m.range.location + m.range.length
                    var after = ns.substring(with: NSRange(location: end, length: min(35, ns.length - end)))
                    if let cut = after.firstIndex(where: { ".;!?".contains($0) }) { after = String(after[..<cut]) }
                    var near = after
                    let bStart = max(0, m.range.location - 35)
                    var lead = ns.substring(with: NSRange(location: bStart, length: m.range.location - bStart))
                    if let cut = lead.lastIndex(where: { ".;!?".contains($0) }) { lead = String(lead[lead.index(after: cut)...]) }
                    near = lead + " " + matched + " " + after
                    if ure.firstMatch(in: near, range: NSRange(location: 0, length: (near as NSString).length)) != nil { continue }
                }
                out.append(Flag(weight: weight >= 5 ? 5 : weight, hard: weight >= 5, soft: rule.soft, reason: rule.reason))
                break
            }
        }
        let letters = t.filter(\.isLetter)
        if letters.count >= 12, Double(letters.filter(\.isUppercase).count) / Double(letters.count) >= 0.7 {
            out.append(Flag(weight: 1, soft: true, reason: "The title is in capitals, shouting for attention."))
        }
        return out
    }
}
