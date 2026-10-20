// What to show first, with no AI: score = 0.55 relevance + 0.20 recency + 0.15 capped log-popularity + 0.10 source trust,
// where relevance is the TF-IDF cosine between an item and the profile's interests (the idf comes from the batch being ranked),
// then an MMR re-rank so three near-duplicates do not fill the digest. The "why" line is a template over the profile's own
// words: nothing from the item's text can reach it. Pure: time and the list of seen ids come in as arguments.
import Foundation

public enum Rank {
    /// An item with its score (0...1) and the interests it matched, in the order of the profile.
    public struct Ranked: Equatable, Sendable {
        public var item: RadarItem
        public var score: Double
        public var matched: [String]
    }

    static let relevanceWeight = 0.55, recencyWeight = 0.20, popularityWeight = 0.15, trustWeight = 0.10
    static let lambda = 0.7  // MMR: 1 = pure score, 0 = pure diversity
    /// A cosine of 0.5 between a short interest list and an abstract is a very good match; typical good ones are 0.1 to 0.4.
    static let relevanceGain = 2.0
    static let popularityCap = 500.0  // upvotes or points that count as "very popular"
    static let dislikePenalty = 0.15, dislikeMax = 0.45
    static let exploreMin = 0.3
    static let day = 86_400.0

    private static let stop: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "can", "do", "does", "for", "from", "had", "has", "have",
        "he", "her", "his", "how", "if", "in", "into", "is", "it", "its", "may", "more", "most", "no", "not", "of", "on", "one",
        "or", "other", "our", "she", "so", "such", "than", "that", "the", "their", "them", "then", "there", "these", "they",
        "this", "those", "to", "was", "we", "were", "what", "when", "where", "which", "while", "who", "will", "with", "you", "your",
    ]

    // MARK: words

    /// Lower-case words of unicode letters and digits (accents composed, so "é" is one word however it was typed), without
    /// one-letter words and a small English stoplist, plurals folded ("robots" is "robot").
    /// ponytail: only plurals are folded, so "robotics" and "robot" differ; list both in the profile if both matter.
    public static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            defer { current = String.UnicodeScalarView() }
            guard current.count >= 2, current.count <= 40 else { return }
            let word = stem(String(current))
            if !stop.contains(word) { out.append(word) }
        }
        for u in text.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars {
            if u.properties.isAlphabetic || u.properties.numericType == .decimal { current.append(u) } else { flush() }
        }
        flush()
        return out
    }

    private static func stem(_ w: String) -> String {
        if w.count > 4, w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
        if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is") { return String(w.dropLast()) }
        return w
    }

    /// What an item is made of for matching: the title twice, the snippet and the tags.
    private static func words(_ item: RadarItem) -> [String] {
        let title = tokens(item.title)
        return title + title + tokens(item.snippet) + item.tags.flatMap(tokens)
    }

    /// Does every word of `phrase` occur in `set`? (An empty phrase matches nothing.)
    private static func has(_ phrase: [String], in set: Set<String>) -> Bool { !phrase.isEmpty && phrase.allSatisfy(set.contains) }

    // MARK: the batch

    private struct Batch {
        var items: [RadarItem] = []
        var relevance: [Double] = []  // gained cosine, 0 = no word in common with any interest
        var matched: [[String]] = []
        var score: [Double] = []
        var popularity: [Double] = []
        var recency: [Double?] = []
        var penalty: [Double] = []
        var vectors: [[String: Double]] = []

        init(_ input: [RadarItem], profile: Profile, now: Date, seen: Set<String>) {
            let groups = dedupe(input.filter { !($0.isOpportunity && ($0.deadline ?? .distantFuture) < now) })
                .filter { $0.ids.isDisjoint(with: seen) }
            let excluded = profile.exclude.map(tokens)
            var docs: [[String]] = []
            for g in groups {
                let doc = words(g.item), set = Set(doc)
                if excluded.contains(where: { has($0, in: set) }) { continue }
                items.append(g.item)
                docs.append(doc)
            }
            let interest = profile.interests.map { tokens($0.text) }
            var weights: [String: Double] = [:]
            for (i, term) in profile.interests.enumerated() { for t in interest[i] { weights[t, default: 0] += term.weight } }
            let (itemVectors, profileVector) = Rank.vectors(docs, profile: weights)
            vectors = itemVectors
            let dislikes = profile.dislikes.map(tokens)
            for (n, item) in items.enumerated() {
                let set = Set(docs[n])
                let hits = profile.interests.indices.filter { has(interest[$0], in: set) }
                    .sorted { (profile.interests[$0].weight, $1) > (profile.interests[$1].weight, $0) }
                let rel = min(1, Rank.dot(itemVectors[n], profileVector) * relevanceGain)
                let pop = item.popularity.map { min(1, log1p($0) / log1p(popularityCap)) } ?? 0
                let rec = Rank.recency(item, now: now)
                let off = min(dislikeMax, dislikePenalty * Double(dislikes.filter { has($0, in: set) }.count))
                var s = relevanceWeight * rel + popularityWeight * pop + trustWeight * item.trust
                s = rec.map { (s + recencyWeight * $0) } ?? s / (1 - recencyWeight)  // no recency: the other weights share it
                relevance.append(rel)
                matched.append(hits.map { profile.interests[$0].text })
                score.append(max(0, s - off))
                popularity.append(pop)
                recency.append(rec)
                penalty.append(off)
            }
        }

        /// `k` of `pool` by MMR: each pick is the best of score minus its similarity to what is already picked.
        func pick(_ pool: [Int], _ k: Int) -> [Int] {
            let sorted = pool.sorted { score[$0] != score[$1] ? score[$0] > score[$1] : items[$0].id < items[$1].id }
            let left = Array(sorted.prefix(150))  // ponytail: MMR over the 150 best; deeper candidates never make a digest
            var closest = [Double](repeating: 0, count: left.count)
            var alive = [Bool](repeating: true, count: left.count)
            var chosen: [Int] = []
            while chosen.count < k {
                var best = -1
                var bestValue = -Double.infinity
                for j in left.indices where alive[j] {
                    let value = lambda * score[left[j]] - (1 - lambda) * closest[j]
                    if value > bestValue + 1e-12 {
                        best = j
                        bestValue = value
                    }
                }
                guard best >= 0 else { break }
                alive[best] = false
                chosen.append(left[best])
                for j in left.indices where alive[j] { closest[j] = max(closest[j], Rank.dot(vectors[left[j]], vectors[left[best]])) }
            }
            return chosen
        }

        func ranked(_ i: Int) -> Ranked { Ranked(item: items[i], score: score[i], matched: matched[i]) }
    }

    /// TF-IDF vectors (sublinear tf, smoothed idf over the batch plus the profile as one more document), unit length.
    private static func vectors(_ docs: [[String]], profile: [String: Double]) -> (docs: [[String: Double]], profile: [String: Double]) {
        var df: [String: Int] = [:]
        for d in docs { for t in Set(d) { df[t, default: 0] += 1 } }
        for t in profile.keys { df[t, default: 0] += 1 }
        let n = Double(docs.count + 1)
        func idf(_ t: String) -> Double { log((n + 1) / (Double(df[t] ?? 0) + 1)) + 1 }
        func unit(_ v: [String: Double]) -> [String: Double] {
            let norm = v.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return norm > 0 ? v.mapValues { $0 / norm } : [:]
        }
        let item = docs.map { d -> [String: Double] in
            var counts: [String: Double] = [:]
            for t in d { counts[t, default: 0] += 1 }
            return unit(counts.reduce(into: [:]) { $0[$1.key] = (1 + log($1.value)) * idf($1.key) })
        }
        return (item, unit(profile.reduce(into: [:]) { $0[$1.key] = $1.value * idf($1.key) }))
    }

    private static func dot(_ a: [String: Double], _ b: [String: Double]) -> Double {
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        return small.reduce(0) { $0 + $1.value * (large[$1.key] ?? 0) }
    }

    /// 0...1, or nil when time does not matter (a programme). A paper's tau is 7 days, news 1 day, an internship posting 21
    /// days; a contest or hackathon counts higher the sooner it starts (14 days), and not at all once it has. No date: 0.3.
    private static func recency(_ item: RadarItem, now: Date) -> Double? {
        switch item.kind {
        case .program:
            return nil
        case .contest, .hackathon:
            guard let start = item.deadline else { return 0.3 }
            let until = start.timeIntervalSince(now)
            return until < 0 ? 0 : exp(-until / (14 * day))
        case .paper, .news, .internship:
            guard let published = item.published else { return 0.3 }
            let tau = item.kind == .paper ? 7 * day : item.kind == .news ? day : 21 * day
            return exp(-max(0, now.timeIntervalSince(published)) / tau)
        }
    }

    // MARK: dedupe

    private static func dedupe(_ items: [RadarItem]) -> [(item: RadarItem, ids: Set<String>)] {
        var out: [(item: RadarItem, ids: Set<String>)] = []
        var byID: [String: Int] = [:], byURL: [String: Int] = [:]
        var titles: [(kind: RadarItem.Kind, words: Set<String>, at: Int)] = []
        for item in items {
            let url = Plain.normalised(item.url)
            let title = Set(tokens(item.title))
            // ponytail: the title pass is O(n^2) over a batch of a few hundred to a thousand items
            let hit = byID[item.id] ?? byURL[url] ?? titles.first { $0.kind == item.kind && similar($0.words, title) }?.at
            if let i = hit {
                out[i].item.absorb(item)
                out[i].ids.insert(item.id)
                byID[item.id] = i
                byURL[url] = i
                continue
            }
            out.append((item, [item.id]))
            byID[item.id] = out.count - 1
            byURL[url] = out.count - 1
            if title.count >= 3 { titles.append((item.kind, title, out.count - 1)) }
        }
        return out
    }

    /// Titles of three words or more that share 85 % of their words.
    private static func similar(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard a.count >= 3, b.count >= 3 else { return false }
        let shared = a.intersection(b).count
        return Double(shared) / Double(a.count + b.count - shared) >= 0.85
    }

    // MARK: the public face

    /// Everything worth showing, best first and varied: duplicates merged, excluded words and passed deadlines dropped, the
    /// dislike list subtracted, then at most `limit` by MMR.
    public static func rank(_ items: [RadarItem], profile: Profile, now: Date, limit: Int = 50) -> [Ranked] {
        let batch = Batch(items, profile: profile, now: now, seen: [])
        return batch.pick(Array(batch.items.indices), limit).map(batch.ranked)
    }

    /// The learning digest: up to 3 papers and 1 news item that match the profile (varied by MMR), plus one explore item that
    /// matches none of it but is popular or fresh. In that order: papers, explore, news. Fewer when there is not enough; an
    /// item whose id is in `seen` (or one that duplicates it) never comes back. Without any interests in the profile nothing
    /// can match, so the papers and the news are simply the best by recency, popularity and trust.
    public static func digest(items: [RadarItem], profile: Profile, now: Date, seen: Set<String> = []) -> [RadarItem] {
        let b = Batch(items.filter { $0.kind == .paper || $0.kind == .news }, profile: profile, now: now, seen: seen)
        let personal = !profile.interests.isEmpty
        func pool(_ kind: RadarItem.Kind) -> [Int] { b.items.indices.filter { b.items[$0].kind == kind && (!personal || b.relevance[$0] > 0) } }
        let papers = b.pick(pool(.paper), 3), news = b.pick(pool(.news), 1)
        let taken = Set(papers + news)
        func surprise(_ i: Int) -> Double { 0.5 * b.popularity[i] + 0.35 * (b.recency[i] ?? 0.5) + 0.15 * b.items[i].trust }
        let explore = b.items.indices.filter { !taken.contains($0) && b.relevance[$0] == 0 && b.penalty[$0] == 0 }
            .max { surprise($0) != surprise($1) ? surprise($0) < surprise($1) : b.items[$0].id > b.items[$1].id }
            .flatMap { surprise($0) >= exploreMin ? $0 : nil }
        return (papers + (explore.map { [$0] } ?? []) + news).map { b.items[$0] }
    }

    /// One templated sentence over the profile's own words: "matches: vision, robotics" (the three heaviest interests that
    /// all appear in the item). No text of the item is in it.
    public static func why(item: RadarItem, profile: Profile) -> String {
        guard !profile.interests.isEmpty else { return "no interests in your profile yet" }
        let set = Set(words(item))
        let hits = profile.interests.enumerated().filter { has(tokens($0.element.text), in: set) }
            .sorted { ($0.element.weight, $1.offset) > ($1.element.weight, $0.offset) }
        return hits.isEmpty ? "outside your interests" : "matches: " + hits.prefix(3).map(\.element.text).joined(separator: ", ")
    }

    /// The words of an item to add to the dislike list when you say "Not for me": its tags, then its title, without any word
    /// that is part of an interest (so disliking one vision paper does not hide all vision).
    public static func dislikeKeywords(for item: RadarItem, profile: Profile, limit: Int = 5) -> [String] {
        let mine = Set(profile.interests.flatMap { tokens($0.text) })
        var seen = Set<String>()
        return Array((item.tags.flatMap(tokens) + tokens(item.title)).filter { !mine.contains($0) && seen.insert($0).inserted }.prefix(max(0, limit)))
    }
}

private extension RadarItem {
    /// A duplicate from another source: keep this item, take what it lacks.
    mutating func absorb(_ other: RadarItem) {
        if let p = other.popularity { popularity = max(popularity ?? 0, p) }
        if published == nil { published = other.published }
        if snippet.isEmpty { snippet = other.snippet }
        for tag in other.tags where tags.count < 8 && !tags.contains(tag) { tags.append(tag) }
    }
}
