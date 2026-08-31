import Foundation

// MARK: - Mathematical Relevance Scoring & Relative Mockbuster Demotion

struct RelevanceScorer: Sendable {
    enum Weight {
        static let exactMatch: Double = 10_000
        static let prefixMatch: Double = 5_000
        static let allTokensMatch: Double = 2_500
        static let partialTokenMatch: Double = 800
        static let substringMatch: Double = 300
        static let popularity: Double = 300
        static let voteCredibility: Double = 150
        static let knockoffPenalty: Double = 9_000
    }

    init() {}

    /// `batchContext` is the full, already-quality-filtered result set for
    /// this query — used to demote a low-vote entry that merely shares a word
    /// with a much bigger, much more credible sibling (e.g. a fan film called
    /// "Transformers: Genesis" sitting next to the real franchise).
    nonisolated func score(candidate: MediaCandidate, query: String, batchContext: [MediaCandidate]) -> Double {
        let normalizedQuery = query.normalizedForSearch
        let normalizedTitle = candidate.title.normalizedForSearch
        guard !normalizedQuery.isEmpty else { return -.infinity }

        var score: Double = 0
        var matched = false

        if normalizedTitle == normalizedQuery {
            score += Weight.exactMatch
            matched = true
        } else if normalizedTitle.hasPrefix(normalizedQuery) {
            score += Weight.prefixMatch
            matched = true
        } else {
            let queryTokens = Set(query.searchTokens)
            let titleTokens = Set(candidate.title.searchTokens)

            if !queryTokens.isEmpty, queryTokens.isSubset(of: titleTokens) {
                score += Weight.allTokensMatch
                matched = true
            } else if !queryTokens.isDisjoint(with: titleTokens) {
                score += Weight.partialTokenMatch
                matched = true
            } else if normalizedTitle.contains(normalizedQuery) {
                score += Weight.substringMatch
                matched = true
            }
        }

        guard matched else { return -.infinity }

        // Logarithmic popularity/credibility scaling — allows an exact-match
        // indie title to outrank a blockbuster on a merely partial match,
        // while rewarding well-known titles among equal-tier matches.
        score += log10(candidate.popularity + 1) * Weight.popularity
        score += log10(Double(candidate.voteCount) + 1) * Weight.voteCredibility

        // Relative Mockbuster / Knockoff Demotion
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
    /// The most popular sibling in this batch that shares at least one
    /// significant title token with `candidate` — used to detect mockbusters
    /// riding on a franchise name.
    func dominantSibling(sharingTokensWith candidate: MediaCandidate) -> MediaCandidate? {
        let candidateTokens = Set(candidate.title.searchTokens)
        guard !candidateTokens.isEmpty else { return nil }

        return self
            .filter { $0.id != candidate.id }
            .filter { !Set($0.title.searchTokens).isDisjoint(with: candidateTokens) }
            .max { $0.popularity < $1.popularity }
    }
}
