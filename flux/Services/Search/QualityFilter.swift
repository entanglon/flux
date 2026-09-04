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
        requireOverview: Bool = true
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

    nonisolated func isEligible(_ candidate: MediaCandidate, now: Date = Date()) -> Bool {
        guard !candidate.isAdult else { return false }

        if config.requirePoster, candidate.posterPath == nil || candidate.posterPath?.isEmpty == true {
            return false
        }
        
        // Cinemeta search results do not bundle an overview/synopsis in the search index;
        // do not reject them if source is cinemeta.
        if candidate.source != .cinemeta {
            if config.requireOverview,
               (candidate.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                return false
            }
        }

        let releaseAgeDays = candidate.releaseDate.map { now.timeIntervalSince($0) / 86_400 }
        let isFreshRelease = (releaseAgeDays ?? .infinity) <= Double(config.recentReleaseGraceDays)
            && (releaseAgeDays ?? -1) >= 0

        if isFreshRelease || candidate.source == .cinemeta {
            // New releases and verified Cinemeta catalog items are exempt from the vote-count/popularity floor
            return true
        }

        if candidate.voteCount < config.minVoteCountThreshold { return false }
        if candidate.popularity < config.minPopularityFloor { return false }

        return true
    }

    nonisolated func filter(_ candidates: [MediaCandidate]) -> [MediaCandidate] {
        candidates.filter { isEligible($0) }
    }
}
