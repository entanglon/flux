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
        // TIER 4: All Query Tokens Match
        else {
            let queryTokens = Set(query.searchTokens)
            let titleTokens = Set(candidate.title.searchTokens)

            if !queryTokens.isEmpty, queryTokens.isSubset(of: titleTokens) {
                score += Weight.allTokensMatch
                matched = true
            }
            // TIER 5: Partial Token Match
            else if !queryTokens.isDisjoint(with: titleTokens) {
                score += Weight.partialTokenMatch
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
            .sorted { $0.1 > $1.1 }
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
