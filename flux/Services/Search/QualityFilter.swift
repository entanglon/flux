import Foundation

// MARK: - Quality Gate Configuration & Pre-Ranking Pruning

struct QualityGateConfig: Sendable, Equatable {
    var minVoteCountThreshold: Int
    var recentReleaseGraceDays: Int
    var minPopularityFloor: Double
    var requirePoster: Bool
    var requireOverview: Bool

    init(
        minVoteCountThreshold: Int = 10,
        recentReleaseGraceDays: Int = 60,
        minPopularityFloor: Double = 1.0,
        requirePoster: Bool = true,
        requireOverview: Bool = false
    ) {
        self.minVoteCountThreshold = minVoteCountThreshold
        self.recentReleaseGraceDays = recentReleaseGraceDays
        self.minPopularityFloor = minPopularityFloor
        self.requirePoster = requirePoster
        self.requireOverview = requireOverview
    }
}

/// Hard, pre-ranking quality gates. Anything that fails these never reaches the
/// scorer — this is what keeps zero-vote mockbusters, fake entries, and student shorts
/// out of the result set entirely.
struct QualityFilter: Sendable {
    let config: QualityGateConfig

    init(config: QualityGateConfig = QualityGateConfig()) {
        self.config = config
    }

    nonisolated func isEligible(_ candidate: MediaCandidate, query: String? = nil, now: Date = Date()) -> Bool {
        guard !candidate.isAdult else { return false }

        let lowerTitle = candidate.title.lowercased()
        let lowerQuery = query?.lowercased() ?? ""

        // Prune commentary and audio riff tracks (e.g. "Rifftrax: Avengers: Endgame")
        if lowerTitle.hasPrefix("rifftrax:") || lowerTitle.hasPrefix("rifftrax -") {
            return false
        }

        // Prune trash/exploitation keywords unless explicitly queried
        let junkKeywords = ["bikini", "parody", "xxx", "porn", "erotic", "mockbuster", "spoof"]
        for kw in junkKeywords {
            if lowerTitle.contains(kw) && !lowerQuery.contains(kw) {
                return false
            }
        }

        // Require valid poster artwork across all sources
        if config.requirePoster {
            guard let poster = candidate.posterPath, !poster.isEmpty else { return false }
        }
        
        let releaseAgeDays = candidate.releaseDate.map { now.timeIntervalSince($0) / 86_400 }
        let isFreshRelease = (releaseAgeDays ?? .infinity) <= Double(config.recentReleaseGraceDays)
            && (releaseAgeDays ?? -1) >= 0
        let isUpcomingRelease = (releaseAgeDays ?? 0) < 0

        // New releases, upcoming releases, and verified Cinemeta catalog items are exempt from the vote-count/popularity floor
        if isFreshRelease || isUpcomingRelease || candidate.source == .cinemeta {
            return true
        }

        // Exact title matches are exempt from the vote-count floor
        if let query = query {
            let normQuery = query.normalizedForSearch.articleStripped
            if candidate.articleStrippedTitle == normQuery || candidate.normalizedTitle == query.normalizedForSearch {
                return true
            }
        }

        // Prune poorly-rated titles (< 5.0 with low popularity)
        if candidate.voteAverage > 0 && candidate.voteAverage < 5.0 && candidate.popularity < 10.0 {
            return false
        }

        // Prune obscure long-tail items with negligible popularity and low votes
        if candidate.popularity < 2.5 && candidate.voteCount < 150 && candidate.source != .cinemeta {
            return false
        }

        if candidate.voteCount < config.minVoteCountThreshold { return false }
        if candidate.popularity < config.minPopularityFloor { return false }

        return true
    }

    nonisolated func filter(_ candidates: [MediaCandidate], query: String? = nil) -> [MediaCandidate] {
        candidates.filter { isEligible($0, query: query) }
    }
}
