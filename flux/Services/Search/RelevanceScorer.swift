import Foundation

// MARK: - Mathematical Relevance Scoring, Franchise Stems & Relative Mockbuster Demotion

struct RelevanceScorer: Sendable {
    enum Weight {
        static let exactMatch: Double = 10_000
        static let franchiseStemExact: Double = 7_000
        static let prefixMatch: Double = 5_000
        static let allTokensMatch: Double = 2_500
        static let partialTokenMatch: Double = 800
        static let substringMatch: Double = 300
        static let fuzzyBase: Double = 150
        static let popularity: Double = 300
        static let voteCredibility: Double = 150
        static let knockoffPenalty: Double = 9_000
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

        // TIER 1: Exact Match (with or without leading "The", "A", "An")
        if candidate.articleStrippedTitle == queryArticleStripped ||
           candidate.normalizedTitle == normalizedQuery {
            score += Weight.exactMatch
            matched = true
        }
        // TIER 2: Franchise Stem Exact Match (e.g. searching "avengers" matches "Avengers: Infinity War")
        // Apply token-ratio penalty so sequels with long subtitles don't beat the original flagship title
        else if candidate.hasSubtitle && candidate.franchiseStem == queryArticleStripped {
            let qTokens = max(normalizedQuery.searchTokens.count, 1)
            let tTokens = max(candidate.articleStrippedTitle.searchTokens.count, 1)
            let ratio = Double(qTokens) / Double(tTokens)
            let penaltyFactor = pow(ratio, 1.5) // (Q / T) ^ 1.5
            score += Weight.franchiseStemExact * penaltyFactor
            matched = true
        }
        // TIER 3: Prefix Match
        else if candidate.articleStrippedTitle.hasPrefix(queryArticleStripped) ||
                candidate.normalizedTitle.hasPrefix(normalizedQuery) {
            score += Weight.prefixMatch
            matched = true
        }
        // TIER 4: All Query Tokens Match (Exact, Plural, or Minor Typo Tolerant)
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
            // TIER 5: Importance-Weighted Partial Token Match
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
            // TIER 6: Substring Match
            else if candidate.normalizedTitle.contains(normalizedQuery) ||
                     candidate.articleStrippedTitle.contains(queryArticleStripped) {
                score += Weight.substringMatch
                matched = true
            }
            // TIER 7: Typo / Damerau-Levenshtein Fuzzy Match
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

        // Logarithmic popularity & credibility scaling
        score += log10(candidate.popularity + 1) * Weight.popularity
        score += log10(Double(candidate.voteCount) + 1) * Weight.voteCredibility

        // Relative Mockbuster Demotion
        if let dominant = batchContext.dominantSibling(sharingTokensWith: candidate),
           dominant.id != candidate.id {
            let popularityRatio = dominant.popularity / max(candidate.popularity, 0.1)
            let voteRatio = Double(dominant.voteCount) / max(Double(candidate.voteCount), 1)
            if popularityRatio > 10, voteRatio > 10, candidate.voteCount < 50 {
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
            .max { $0.popularity < $1.popularity }
    }
}
