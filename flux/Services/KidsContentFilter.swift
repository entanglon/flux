import Foundation

/// Service responsible for classifying media age ratings, maintaining a persistent
/// certification cache, and filtering content for the Kids Profile.
final class KidsContentFilter: @unchecked Sendable {
    static let shared = KidsContentFilter()

    // MARK: - Rating Definitions (Rating Ceiling: G, PG, TV-Y, TV-Y7, TV-G, TV-PG)

    /// Whitelisted age rating certifications allowed in Kids mode.
    private let allowedCertifications: Set<String> = [
        "G", "PG",
        "TV-Y", "TVY",
        "TV-Y7", "TVY7", "TV-Y7-FV",
        "TV-G", "TVG",
        "TV-PG", "TVPG",
        "U", // UK
        "0", "6", "FSK 0", "FSK 6", "FSK0", "FSK6", // Germany
        "APPROVED", "PASSED", "GENERAL", "E"
    ]

    /// Explicitly blocked age rating certifications in Kids mode.
    private let blockedCertifications: Set<String> = [
        "PG-13", "PG13",
        "R", "NC-17", "NC17",
        "TV-14", "TV14",
        "TV-MA", "TVMA",
        "12", "12A", "15", "18", "16",
        "M", "MA15+", "R18+", "X", "XXX",
        "A", // India (Adults)
        "NR", "NOT RATED", "UNRATED", "UR"
    ]

    /// Explicitly adult genres that immediately disqualify an item.
    private let adultGenres: Set<String> = [
        "horror", "crime", "thriller", "war", "erotic", "erotica", "adult",
        "mystery", "documentary", "reality-tv", "news", "talk"
    ]

    /// Known safe family/kids genres.
    private let safeFamilyGenres: Set<String> = [
        "animation", "family", "kids", "children"
    ]

    /// Curated safe genre names visible under Browse in Kids mode.
    public static let safeBrowseGenreNames: Set<String> = [
        "Animation", "Adventure", "Comedy", "Fantasy", "Short Films", "Family", "Kids"
    ]

    /// Whether a given genre category is suitable for Kids profile browsing.
    func isGenreSafeForKids(_ genreName: String) -> Bool {
        Self.safeBrowseGenreNames.contains(genreName)
    }

    // MARK: - Adult Franchise and Title Blacklist

    /// Known adult franchises, titles, or horror adaptations that should never appear in Kids mode,
    /// even if miscategorized as "Animation" or lacking certification metadata in keyless/fallback mode.
    private static let blockedTitlePatterns: [String] = [
        "south park", "family guy", "rick and morty", "invincible", "attack on titan",
        "demon slayer", "jujutsu kaisen", "chainsaw man", "death note", "bleach",
        "berserk", "deadpool", "archer", "bojack horseman", "big mouth", "castlevania",
        "cyberpunk", "sausage party", "fritz the cat", "helluva boss", "hazbin hotel",
        "harley quinn", "the boys", "solar opposites", "paradise pd", "brickleberry",
        "robot chicken", "aqua teen", "beavis and butt-head", "beavis and butthead",
        "american dad", "the cleveland show", "drawn together", "metalocalypse",
        "venture bros", "spawn", "tokyo ghoul", "hellsing", "elfen lied", "parasyte",
        "grave of the fireflies", "batman: the killing joke", "batman: knightfall",
        "heavy metal", "love, death & robots", "arcane", "blue eye samurai",
        "fist of the north star", "ninja scroll", "akira", "ghost in the shell",
        "perfect blue", "paprika", "blood and honey", "pinocchio: unstrung",
        "pinocchio unstrung", "bambi: the reckoning", "peter pan's neverland",
        "cinderella's curse", "sleeping beauty's massacre", "the mean one",
        "toxic", "toxic avenger", "fifty shades", "terrifier", "saw", "halloween",
        "scream", "friday the 13th", "a nightmare on elm street", "chucky", "child's play",
        "the conjuring", "insidious", "evil dead", "the exorcist", "smile", "the substance",
        "longlegs", "heretic", "nosferatu", "alien", "predator", "resident evil",
        "silent hill", "mortal kombat", "blade", "punisher", "sin city", "watchmen",
        "constantine", "peacemaker", "the walking dead", "game of thrones",
        "breaking bad", "dexter", "hannibal", "stranger things", "squid game", "euphoria"
    ]

    /// Keywords in description or overview that signal adult themes.
    private static let adultDescriptionKeywords: [String] = [
        "foul-mouthed", "bloodshed", "unsettling tale", "gory", "gore", "slasher",
        "disturbing journey", "disturbing tale", "psychological horror", "brutal",
        "murderous", "gruesome", "nudity", "profanity", "slaughter", "drug cartel",
        "serial killer", "underworld", "erotic", "sexually"
    ]

    /// Pre-seeded known certifications for instant offline & keyless evaluation.
    private static let preseededCertifications: [String: String] = [
        // Safe Classics & Hits
        "toy story": "G", "toy story 2": "G", "toy story 3": "G", "toy story 4": "G",
        "finding nemo": "G", "finding dory": "PG",
        "cars": "G", "cars 2": "G", "cars 3": "G",
        "the lion king": "G", "aladdin": "G", "beauty and the beast": "G",
        "mulan": "G", "tarzan": "G", "hercules": "G", "cinderella": "G",
        "snow white": "G", "pinocchio": "G", "bambi": "G", "dumbo": "G",
        "frozen": "PG", "frozen 2": "PG", "moana": "PG", "moana 2": "PG",
        "zootopia": "PG", "zootopia 2": "PG", "encanto": "PG", "tangled": "PG",
        "coco": "PG", "inside out": "PG", "inside out 2": "PG", "up": "PG",
        "wall-e": "G", "monsters, inc.": "G", "monsters inc": "G", "monsters university": "G",
        "ratatouille": "G", "the incredibles": "PG", "incredibles 2": "PG",
        "despicable me": "PG", "despicable me 2": "PG", "despicable me 3": "PG", "despicable me 4": "PG",
        "minions": "PG", "minions: the rise of gru": "PG",
        "kung fu panda": "PG", "kung fu panda 2": "PG", "kung fu panda 3": "PG", "kung fu panda 4": "PG",
        "how to train your dragon": "PG", "how to train your dragon 2": "PG", "how to train your dragon 3": "PG",
        "shrek": "PG", "shrek 2": "PG", "shrek the third": "PG", "shrek forever after": "PG",
        "puss in boots": "PG", "puss in boots: the last wish": "PG",
        "the wild robot": "PG", "paddington": "PG", "paddington 2": "PG",
        "spirited away": "PG", "my neighbor totoro": "G", "kiki's delivery service": "G",
        "avatar: the last airbender": "TV-Y7", "spongebob squarepants": "TV-Y7",
        "bluey": "TV-Y", "peppa pig": "TV-Y", "paw patrol": "TV-Y",
        "gravity falls": "TV-Y7", "phineas and ferb": "TV-G",
        // Known Restricted Titles
        "toxic": "R", "pinocchio: unstrung": "R", "pinocchio unstrung": "R",
        "south park": "TV-MA", "family guy": "TV-14", "rick and morty": "TV-14",
        "invincible": "TV-MA", "attack on titan": "TV-MA", "demon slayer": "R",
        "deadpool": "R", "deadpool 2": "R", "deadpool & wolverine": "R",
        "chainsaw man": "TV-MA", "jujutsu kaisen": "TV-14", "death note": "TV-14",
        "bleach": "TV-14", "berserk": "TV-MA", "archer": "TV-MA",
        "bojack horseman": "TV-MA", "big mouth": "TV-MA", "castlevania": "TV-MA"
    ]

    func isTitleBlocked(_ title: String) -> Bool {
        let lower = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        for pattern in Self.blockedTitlePatterns {
            if pattern.count <= 5 {
                // Exact word match or clear prefix/suffix to avoid substring overmatching on short terms
                if lower == pattern || lower.hasPrefix("\(pattern):") || lower.hasPrefix("\(pattern) ") || lower.hasSuffix(" \(pattern)") {
                    return true
                }
            } else {
                if lower == pattern || lower.contains(pattern) {
                    return true
                }
            }
        }
        return false
    }

    func isDescriptionRestricted(_ text: String?) -> Bool {
        guard let desc = text?.lowercased(), !desc.isEmpty else { return false }
        for kw in Self.adultDescriptionKeywords {
            if desc.contains(kw) { return true }
        }
        return false
    }

    // MARK: - Caching

    private let cacheQueue = DispatchQueue(label: "flux.kidsContentFilter.cache", attributes: .concurrent)
    private var certCache: [String: String] = [:]
    private var safetyCache: [String: Bool] = [:]
    private let diskCacheURL: URL?

    init(diskStorage: Bool = true) {
        if diskStorage {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let fluxDir = appSupport?.appendingPathComponent("flux", isDirectory: true)
            if let dir = fluxDir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                self.diskCacheURL = dir.appendingPathComponent("flux_certifications_cache.json")
            } else {
                self.diskCacheURL = nil
            }
        } else {
            self.diskCacheURL = nil
        }
        loadDiskCache()
    }

    // MARK: - Rating Classification

    /// Evaluates whether a raw certification string (e.g. "PG", "TV-14", "R") is safe for kids.
    func isCertificationSafe(_ rawCert: String?) -> Bool {
        guard let cert = rawCert?.trimmingCharacters(in: .whitespacesAndNewlines), !cert.isEmpty else {
            return false
        }
        let clean = normalizeCertification(cert)
        if blockedCertifications.contains(clean) {
            return false
        }
        if allowedCertifications.contains(clean) {
            return true
        }
        // Partial prefixes (e.g. "PG-13 / TV-14" or international variant)
        if clean.contains("PG-13") || clean.contains("PG13") || clean.contains("TV-14") || clean.contains("TV-MA") || clean.contains("R") {
            return false
        }
        return false
    }

    /// Evaluates whether a MediaItem is safe for the Kids Profile.
    func isKidsSafe(item: MediaItem) async -> Bool {
        // 1. Explicit title blacklist (immediate rejection)
        if isTitleBlocked(item.title) {
            setCached(item.id, cert: "R", isSafe: false)
            return false
        }

        // 2. Check in-memory safety cache
        if let cached = getCachedSafety(for: item.id) {
            return cached
        }

        // 3. Description keyword scan
        if isDescriptionRestricted(item.description) {
            setCached(item.id, cert: "R", isSafe: false)
            return false
        }

        // 4. Check pre-seeded known certifications
        let cleanTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let seeded = Self.preseededCertifications[cleanTitle] {
            let safe = isCertificationSafe(seeded)
            setCached(item.id, cert: seeded, isSafe: safe)
            return safe
        }

        // 5. Immediate check if item already has certification attached
        if let cert = item.certification, !cert.isEmpty {
            let safe = isCertificationSafe(cert)
            setCached(item.id, cert: cert, isSafe: safe)
            return safe
        }

        // 6. Check cached certification
        if let cachedCert = getCachedCert(for: item.id) {
            let safe = isCertificationSafe(cachedCert)
            setCached(item.id, cert: cachedCert, isSafe: safe)
            return safe
        }

        // 7. Resolve certification from TMDB
        let cleanType = item.category.lowercased().contains("tv") || item.category.lowercased().contains("series") ? "tv" : "movie"
        let cleanID = item.id.replacingOccurrences(of: "tmdb-", with: "").replacingOccurrences(of: "tmdb:", with: "")
        let tmdbID = item.id.starts(with: "tt")
            ? await TMDBEnricher.shared.resolveTmdbID(imdbID: item.id, type: cleanType)
            : cleanID

        if let id = tmdbID {
            let (cert, _) = await TMDBEnricher.shared.fetchCertification(id: id, type: cleanType)
            if let cert = cert, !cert.isEmpty {
                let safe = isCertificationSafe(cert)
                setCached(item.id, cert: cert, isSafe: safe)
                return safe
            }
        }

        // 8. Default-Block-Unknown Policy with safe family genre exemption
        let itemGenres = (item.genres ?? []).map { $0.lowercased() }
        let hasAdultGenre = itemGenres.contains { adultGenres.contains($0) }
        let hasExplicitFamilyOrKids = itemGenres.contains { $0 == "family" || $0 == "kids" || $0 == "children" }

        let safe: Bool
        if hasAdultGenre {
            safe = false
        } else if hasExplicitFamilyOrKids {
            safe = true
        } else if itemGenres.contains("animation") && (itemGenres.contains("adventure") || itemGenres.contains("comedy") || itemGenres.contains("fantasy")) {
            // General animation without Family tag: only allow if not flagged by any adult check
            // and has at least one wholesome supporting genre
            safe = true
        } else {
            // Strict default-block-unknown for items without certification or safe genres
            safe = false
        }

        setCached(item.id, cert: nil, isSafe: safe)
        return safe
    }

    /// Synchronous restriction probe (used by DetailView & Player to quickly flag known restricted titles).
    func isRestricted(item: MediaItem) -> Bool {
        // 1. Explicit title blacklist
        if isTitleBlocked(item.title) {
            return true
        }

        // 2. Preseeded certification lookup
        let cleanTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let seeded = Self.preseededCertifications[cleanTitle] {
            return !isCertificationSafe(seeded)
        }

        // 3. Attached certification
        if let cert = item.certification, !cert.isEmpty {
            return !isCertificationSafe(cert)
        }

        // 4. Cached certification
        if let cachedCert = getCachedCert(for: item.id) {
            return !isCertificationSafe(cachedCert)
        }

        // 5. Cached safety decision
        if let cachedSafety = getCachedSafety(for: item.id) {
            return !cachedSafety
        }

        // 6. Adult description keywords
        if isDescriptionRestricted(item.description) {
            return true
        }

        // 7. Adult genres check
        let itemGenres = (item.genres ?? []).map { $0.lowercased() }
        if itemGenres.contains(where: { adultGenres.contains($0) }) {
            return true
        }

        return false
    }

    /// Filters an array of media items, preserving original ordering, retaining only kids-safe items.
    func filterSafeItems(_ items: [MediaItem]) async -> [MediaItem] {
        guard !items.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    let safe = await self.isKidsSafe(item: item)
                    return (index, safe)
                }
            }

            var keep = [Bool](repeating: false, count: items.count)
            for await (index, safe) in group {
                keep[index] = safe
            }

            return items.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
        }
    }

    // MARK: - Normalization & Caching Helpers

    private func normalizeCertification(_ cert: String) -> String {
        cert.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "RATED ", with: "")
            .replacingOccurrences(of: "FSK-", with: "FSK ")
    }

    private func getCachedSafety(for id: String) -> Bool? {
        cacheQueue.sync { safetyCache[id] }
    }

    private func getCachedCert(for id: String) -> String? {
        cacheQueue.sync { certCache[id] }
    }

    func setCached(_ id: String, cert: String?, isSafe: Bool) {
        cacheQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.safetyCache[id] = isSafe
            if let c = cert {
                self.certCache[id] = c
            }
            self.scheduleDiskSave()
        }
    }

    func resetCacheForTesting() {
        cacheQueue.sync(flags: .barrier) {
            safetyCache.removeAll()
            certCache.removeAll()
        }
    }

    // MARK: - Disk Persistence

    private func scheduleDiskSave() {
        guard let url = diskCacheURL else { return }
        let snapshot = certCache
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func loadDiskCache() {
        guard let url = diskCacheURL,
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        cacheQueue.sync(flags: .barrier) {
            self.certCache = dict
            for (id, cert) in dict {
                self.safetyCache[id] = self.isCertificationSafe(cert)
            }
        }
    }
}
