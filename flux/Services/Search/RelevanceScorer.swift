import Foundation

// MARK: - Mathematical Relevance Scoring, Franchise Stems & Relative Mockbuster Demotion

struct RelevanceScorer: Sendable {
    enum Weight {
        static let exactMatch: Double = 10_000
        static let franchiseStemExact: Double = 10_000
        static let prefixMatch: Double = 6_000
        static let allTokensMatch: Double = 3_500
        static let partialTokenMatch: Double = 1_000
        static let substringMatch: Double = 400
        static let fuzzyBase: Double = 200
        static let popularity: Double = 600
        static let voteCredibility: Double = 1_200
        static let knockoffPenalty: Double = 15_000
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "of", "and", "in", "on", "at", "to", "for", "with", "by", "from"
    ]

    private static func tokenMatches(q: String, t: String) -> Bool {
        if q == t { return true }
        // Plural / singular matching (e.g. "waters" vs "water", "heroes" vs "hero")
        if q.hasSuffix("s") && String(q.dropLast()) == t { return true }
        if t.hasSuffix("s") && String(t.dropLast()) == q { return true }
        if q.hasSuffix("es") && String(q.dropLast(2)) == t { return true }
        if t.hasSuffix("es") && String(t.dropLast(2)) == q { return true }
        
        // Minor typo tolerance for longer words (length >= 4)
        if q.count >= 4 && t.count >= 4 && abs(q.count - t.count) <= 1 {
            if DamerauLevenshtein.distance(q, t) <= 1 {
                return true
            }
        }
        return false
    }

    init() {}

    /// `batchContext` is the full, already-quality-filtered result set for this query.
    nonisolated func score(candidate: MediaCandidate, query: String, batchContext: [MediaCandidate]) -> Double {
        let normalizedQuery = query.normalizedForSearch
        let queryArticleStripped = normalizedQuery.articleStripped
        guard !normalizedQuery.isEmpty else { return -.infinity }

        var score: Double = 0
        var matched = false

        let cal = Calendar(identifier: .gregorian)
        let releaseYear = candidate.releaseDate.map { cal.component(.year, from: $0) }
        let now = Date()
        let isUpcoming = candidate.releaseDate.map { $0 > now } ?? false

        let qTokens = queryArticleStripped.searchTokens.map(String.init)
        let tTokens = candidate.articleStrippedTitle.searchTokens.map(String.init)

        let isExactMatch: Bool = {
            if candidate.articleStrippedTitle == queryArticleStripped ||
               candidate.normalizedTitle == normalizedQuery {
                return true
            }
            // Token-level exact match with plural/singular stemming (e.g. "game of throne" == "game of thrones")
            if !qTokens.isEmpty && qTokens.count == tTokens.count {
                return zip(qTokens, tTokens).allSatisfy { Self.tokenMatches(q: $0, t: $1) }
            }
            return false
        }()

        let isPrefixMatch: Bool = {
            let tNorm = candidate.normalizedTitle
            let tStripped = candidate.articleStrippedTitle
            let separators = [" ", ":", "-", " — ", " – "]
            for sep in separators {
                if tStripped.hasPrefix(queryArticleStripped + sep) || tNorm.hasPrefix(normalizedQuery + sep) {
                    return true
                }
            }
            if candidate.hasSubtitle && candidate.franchiseStem == queryArticleStripped {
                return true
            }
            // Stemmed token prefix match (e.g. candidate "game of thrones: conquest & rebellion" with query "game of throne")
            if !qTokens.isEmpty && tTokens.count > qTokens.count {
                let leadingTokens = Array(tTokens.prefix(qTokens.count))
                if zip(qTokens, leadingTokens).allSatisfy({ Self.tokenMatches(q: $0, t: $1) }) {
                    return true
                }
            }
            return false
        }()

        // TIER 1: Exact Match (with or without leading "The", "A", "An")
        if isExactMatch {
            score += Weight.exactMatch
            matched = true
        }
        // TIER 2: Franchise & Word-Boundary Prefix Match (e.g. "Harry Potter and...", "Avengers: Endgame", "Batman Begins")
        // Franchise installments share the top-tier alongside the root title
        else if isPrefixMatch {
            let qCount = queryArticleStripped.searchTokens.count
            let tCount = candidate.articleStrippedTitle.searchTokens.count
            let extraTokens = max(tCount - qCount, 0)
            // High franchise tier: 9,500 base with gentle length decay (-50 per word, max 400)
            score += 9_500.0 - min(Double(extraTokens) * 50.0, 400.0)
            matched = true
        }
        // TIER 3: All Query Tokens Match (Exact, Plural, or Minor Typo Tolerant)
        else {
            let qTokens = query.searchTokens.map(String.init)
            let tTokens = candidate.title.searchTokens.map(String.init)
            let nonStopQTokens = qTokens.filter { !Self.stopWords.contains($0) }

            let matchedQTokens = qTokens.filter { q in
                tTokens.contains(where: { Self.tokenMatches(q: q, t: $0) })
            }
            let matchedNonStopQTokens = nonStopQTokens.filter { q in
                tTokens.contains(where: { Self.tokenMatches(q: q, t: $0) })
            }

            let allTokensMatched = !qTokens.isEmpty && (
                matchedQTokens.count == qTokens.count ||
                (!nonStopQTokens.isEmpty && matchedNonStopQTokens.count == nonStopQTokens.count)
            )

            if allTokensMatched {
                score += Weight.allTokensMatch
                matched = true
            }
            // TIER 4: Importance-Weighted Partial Token Match
            else if !matchedQTokens.isEmpty {
                let totalQueryWeight = qTokens.reduce(0.0) { $0 + (Self.stopWords.contains($1) ? 0.2 : 1.0) }
                let matchedQueryWeight = matchedQTokens.reduce(0.0) { $0 + (Self.stopWords.contains($1) ? 0.2 : 1.0) }
                let queryCoverage = totalQueryWeight > 0 ? (matchedQueryWeight / totalQueryWeight) : 0
                
                let matchedTTokensCount = tTokens.filter { t in qTokens.contains(where: { Self.tokenMatches(q: $0, t: t) }) }.count
                let titleDensity = tTokens.isEmpty ? 0 : Double(matchedTTokensCount) / Double(tTokens.count)

                // Scale partialTokenMatch by query coverage and title density
                let partialScore = Weight.partialTokenMatch * (0.6 * queryCoverage + 0.4 * titleDensity)
                score += partialScore
                matched = true
            }
            // TIER 5: Substring Match
            else if candidate.normalizedTitle.contains(normalizedQuery) ||
                     candidate.articleStrippedTitle.contains(queryArticleStripped) {
                score += Weight.substringMatch
                matched = true
            }
            // TIER 6: Typo / Damerau-Levenshtein Fuzzy Match
            else {
                let maxDist = DamerauLevenshtein.maxDistance(forQueryLength: queryArticleStripped.count)
                if maxDist > 0 {
                    let dist = min(
                        DamerauLevenshtein.distance(queryArticleStripped, candidate.articleStrippedTitle),
                        DamerauLevenshtein.distance(queryArticleStripped, candidate.franchiseStem)
                    )
                    if dist <= maxDist {
                        score += Weight.fuzzyBase / Double(1 + dist)
                        matched = true
                    }
                }
            }
        }

        guard matched else { return -.infinity }

        // Vintage TV series demotion: only for television series older than 1980 on ambiguous single-word queries (e.g. 1961 The Avengers)
        if candidate.mediaType == .tvSeries && queryArticleStripped.searchTokens.count == 1 {
            if let year = releaseYear, year < 1980 {
                score -= 1500.0
            }
        }

        // Upcoming release modifier: ensure already-released blockbusters rank ahead of future announcements
        if isUpcoming {
            score -= 2500.0
        }

        // Audience Reach & Popularity logarithmic scaling
        score += log10(candidate.popularity + 1.0) * Weight.popularity
        score += log10(Double(candidate.voteCount) + 1.0) * Weight.voteCredibility

        // Universal Mockbuster & Parody Demotion
        let lowerCandidateTitle = candidate.normalizedTitle
        let isKnownMockbusterOrParody = lowerCandidateTitle.contains("grimm") ||
                                       lowerCandidateTitle.contains("asylum") ||
                                       lowerCandidateTitle.contains("rifftrax")

        if isKnownMockbusterOrParody {
            score -= Weight.knockoffPenalty
        } else if let dominant = batchContext.dominantSibling(sharingTokensWith: candidate),
                  dominant.id != candidate.id {
            let popularityRatio = dominant.popularity / max(candidate.popularity, 0.1)
            let voteRatio = Double(dominant.voteCount) / max(Double(candidate.voteCount), 1.0)
            if dominant.voteCount >= 1000 && (voteRatio > 15.0 || popularityRatio > 8.0) && candidate.voteAverage < 6.0 {
                score -= Weight.knockoffPenalty
            }
        }

        return score
    }

    nonisolated func rank(candidates: [MediaCandidate], query: String) -> [MediaCandidate] {
        candidates
            .map { ($0, score(candidate: $0, query: query, batchContext: candidates)) }
            .filter { $0.1 > -.infinity }
            .sorted { a, b in
                if abs(a.1 - b.1) > 0.001 {
                    return a.1 > b.1
                }
                if a.0.popularity != b.0.popularity {
                    return a.0.popularity > b.0.popularity
                }
                if a.0.voteCount != b.0.voteCount {
                    return a.0.voteCount > b.0.voteCount
                }
                return (a.0.releaseDate ?? Date.distantPast) > (b.0.releaseDate ?? Date.distantPast)
            }
            .map(\.0)
    }
}

private extension Array where Element == MediaCandidate {
    func dominantSibling(sharingTokensWith candidate: MediaCandidate) -> MediaCandidate? {
        let candidateTokens = Set(candidate.title.searchTokens)
        guard !candidateTokens.isEmpty else { return nil }

        return self
            .filter { $0.id != candidate.id }
            .filter { !Set($0.title.searchTokens).isDisjoint(with: candidateTokens) }
            .max { $0.voteCount < $1.voteCount }
    }
}
