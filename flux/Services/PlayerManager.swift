import SwiftUI
import Combine
import _Concurrency

typealias AsyncTask = _Concurrency.Task

class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    @Published var currentItem: MediaItem?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var availableStreams: [Stream] = []
    @Published var currentStreamURL: URL?
    @Published var externalSubtitles: [StremioSubtitleTrack] = []
    
    // Track current episode
    var currentSeason: Int?
    var currentEpisode: Int?
    var currentEpisodeImage: URL?
    
    // Cache for last played URL per episode to enable instant playback on re-open
    private struct CachedStream {
        let url: URL
        let timestamp: Date
    }
    private var lastPlayedStreams: [String: CachedStream] = [:]
    
    private init() {}
    
    func play(_ item: MediaItem, season: Int? = nil, episode: Int? = nil, episodeImage: URL? = nil) {
        self.currentItem = item
        self.currentSeason = season
        self.currentEpisode = episode
        self.currentEpisodeImage = episodeImage
        self.errorMessage = nil
        self.availableStreams = []
        self.currentStreamURL = nil
        self.resetPreloadState()
        
        // 0. Offline Check
        if let localUrl = DownloadManager.shared.getLocalUrl(for: item) {
            print("[PlayerManager] Playing downloaded file: \(localUrl)")
            self.currentStreamURL = localUrl
            self.isLoading = false
            return
        }
        
        // 1. Instant Replay Check
        let key = item.category == "TV Show" ? "\(item.id):\(season ?? 1):\(episode ?? 1)" : "\(item.id)"
        
        if let cached = lastPlayedStreams[key] {
            let elapsed = Date().timeIntervalSince(cached.timestamp)
            
            // If Fresh (< 60 mins), Play Immediately
            if elapsed < 3600 {
                print("[PlayerManager] Cache Fresh (\(Int(elapsed/60))m): Playing immediately.")
                self.currentStreamURL = cached.url
                self.isLoading = false
                self.populateStreamsInBackground(item: item, season: season, episode: episode)
                return
            } else {
                // Cache Stale, Validate
                print("[PlayerManager] Cache Stale (\(Int(elapsed/60))m): Validating...")
                AsyncTask {
                    if await validateStream(cached.url) {
                        print("[PlayerManager] Validation Success. Playing.")
                        await MainActor.run {
                            self.currentStreamURL = cached.url
                            self.isLoading = false
                            // Update timestamp to extend validity
                            self.lastPlayedStreams[key] = CachedStream(url: cached.url, timestamp: Date())
                        }
                        self.populateStreamsInBackground(item: item, season: season, episode: episode)
                    } else {
                        print("[PlayerManager] Validation Failed. Refetching.")
                        await MainActor.run {
                            self.lastPlayedStreams.removeValue(forKey: key)
                            self.fetchAndRace(item: item, season: season, episode: episode)
                        }
                    }
                }
                return // Async validation owns the flow now
            }
        }
        
        // 2. Normal Flow
        fetchAndRace(item: item, season: season, episode: episode)
    }
    
    private func populateStreamsInBackground(item: MediaItem, season: Int?, episode: Int?) {
        AsyncTask {
            // Delay to prevent network contention with video playback start
            try? await AsyncTask.sleep(nanoseconds: 3 * 1_000_000_000)
            
            if let cached = StreamManager.shared.getCachedStreams(for: item, season: season, episode: episode) {
                 await MainActor.run { self.availableStreams = cached }
            } else {
                 let streams = await StreamManager.shared.fetchStreams(for: item, season: season, episode: episode)
                 await MainActor.run { self.availableStreams = streams }
            }
        }
    }

    private func fetchAndRace(item: MediaItem, season: Int?, episode: Int?) {
        // Caching Optimization: Check if we already have streams
        if let cachedStreams = StreamManager.shared.getCachedStreams(for: item, season: season, episode: episode), !cachedStreams.isEmpty {
             print("[PlayerManager] Cache Hit! Ready to Race.")
             self.availableStreams = cachedStreams
             self.isLoading = true // Briefly to setup Flux
        } else {
             self.isLoading = true
        }
        
        AsyncTask {
            _ = await StreamManager.shared.fetchStreams(for: item, season: season, episode: episode) // Ensuring cache init
            
            // Parallel fetch streams and subtitles
            async let streamsTask = StreamManager.shared.fetchStreams(for: item, season: season, episode: episode)
            async let subsTask = SubtitleManager.shared.fetchSubtitles(for: item, season: season, episode: episode)
            
            let streams = await streamsTask
            let extraSubs = await subsTask
            
            await MainActor.run {
                self.externalSubtitles = extraSubs
            }
            
            // Flux Mode Debugging
            let isFluxEnabled = UserDefaults.standard.object(forKey: "enableFluxMode") as? Bool ?? true
            print("[DEBUG] Flux Mode Enabled: \(isFluxEnabled)")
            print("[DEBUG] Stream Count: \(streams.count)")
            print("[DEBUG] Worker URL from Secrets: \(Secrets.streamRacerUrl)")

            // Check for Flux Mode
            if isFluxEnabled,
               !streams.isEmpty {
                
                print("Flux Mode Enabled: Racing \(streams.count) streams...")
                
                // Don't show list yet if we are racing
                // We keep availableStreams populated but rely on isLoading or a racing state?
                // Actually, if we set availableStreams, the UI shows it.
                // Let's NOT set availableStreams in the async block above if we are gonna race.
                // But we need to know IF we are gonna race.
                
                // Optimization: Don't race all streams to avoid timeouts
                // Select top 5 from WebStreamer and top 5 from Nuvio
                let webStreamerStreams = streams.filter { $0.source == "WebStreamer" }.prefix(5)
                let nuvioStreams = streams.filter { $0.source == "Nuvio" }.prefix(5)
                
                let streamsToRace = Array(webStreamerStreams) + Array(nuvioStreams)
                print("Flux Mode Optimization: Racing limited set of \(streamsToRace.count) streams (Top 5 WS + Top 5 Nuvio)")
                
                let streamUrls = streamsToRace.compactMap { $0.url }
                
                // Use URL from Secrets
                if let workerUrl = URL(string: Secrets.streamRacerUrl),
                   let winnerUrl = try? await StreamRacerService.shared.race(workerURL: workerUrl, streamURLs: streamUrls) {
                     DispatchQueue.main.async {
                         self.isLoading = false
                         print("Flux Mode Winner: \(winnerUrl)")
                         
                         // Populate availableStreams so we have a fallback queue, but UI won't show it because currentStreamURL is set
                         self.availableStreams = streams
                         self.currentStreamURL = winnerUrl
                         self.saveLastPlayedStream(url: winnerUrl) // Save for Instant Replay
                         
                         // Add to History
                         if let item = self.currentItem {
                             UserDataService.shared.addToHistory(item, season: self.currentSeason, episode: self.currentEpisode, episodeImage: self.currentEpisodeImage)
                         }
                     }
                     return
                } else {
                    print("Flux Mode Racing failed or no winner. Attempting local fallback.")
                    
                    // Fallback Strategy: Auto-select the first stream (which is sorted by Sticky Source -> WebStreamer -> Quality)
                    // This duplicates the success logic but with the top list item
                    if let firstStream = streams.first {
                        DispatchQueue.main.async {
                            self.isLoading = false
                            print("Fallback Auto-Select: \(firstStream.title) from \(firstStream.source)")
                            self.currentStreamURL = firstStream.url
                            self.saveLastPlayedStream(url: firstStream.url) // Save for Instant Replay
                             
                            // Add to History
                            if let item = self.currentItem {
                                UserDataService.shared.addToHistory(item, season: self.currentSeason, episode: self.currentEpisode, episodeImage: self.currentEpisodeImage)
                            }
                        }
                        return
                    }
                    // If no streams at all (shouldn't happen due to !streams.isEmpty check), fall through to list
                }
            }
            
            // Fallback: Show list
            DispatchQueue.main.async {
                self.availableStreams = streams
                self.isLoading = false
            }
        }
    }
    
    func selectStream(_ stream: Stream) {
        print("Selected stream: \(stream.title) from \(stream.source)")
        self.currentStreamURL = stream.url
        // We keep availableStreams populated in case they want to switch (though UI might hide it)
        
        self.saveLastPlayedStream(url: stream.url)
        
        // Add to History
        if let item = self.currentItem {
            UserDataService.shared.addToHistory(item, season: self.currentSeason, episode: self.currentEpisode, episodeImage: self.currentEpisodeImage)
        }
        
        // Save Sticky Source Preference
        UserDefaults.standard.set(stream.source, forKey: "lastUsedSource")
    }
    
    private func saveLastPlayedStream(url: URL) {
        guard let item = currentItem else { return }
        let key = item.category == "TV Show" ? "\(item.id):\(currentSeason ?? 1):\(currentEpisode ?? 1)" : "\(item.id)"
        lastPlayedStreams[key] = CachedStream(url: url, timestamp: Date())
        print("[PlayerManager] Saved Instant Replay URL for \(key)")
    }
    
    // HEAD request validation
    private func validateStream(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3 // Short timeout, we want fast answer
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                // 200 OK or 206 Partial Content (common for streams) are good
                return httpResponse.statusCode == 200 || httpResponse.statusCode == 206
            }
            return false
        } catch {
            return false
        }
    }
    
    func updateWatchProgress(time: Double, duration: Double) {
        guard let item = currentItem, duration > 0 else { return }
        let progress = time / duration
        UserDataService.shared.addToHistory(item, progress: progress, season: currentSeason, episode: currentEpisode, episodeImage: currentEpisodeImage)
    }
    
    func close() {
        DispatchQueue.main.async {
            self.currentItem = nil
            // Don't clear lastPlayedStreams, it persists for the session
            self.currentStreamURL = nil
            self.availableStreams = []
            self.externalSubtitles = []
            self.isLoading = false
            self.errorMessage = nil
            self.currentSeason = nil
            self.currentEpisode = nil
            self.currentEpisodeImage = nil
        }
    }
    
    // MARK: - Next Episode Logic
    
    var nextEpisodeInfo: (season: Int, episode: Int)? {
        guard let item = currentItem,
              let currentSeasonNum = currentSeason,
              let currentEpisodeNum = currentEpisode,
              let seasons = item.seasons else { return nil }
        
        // 1. Check current season
        if let currentSeasonObj = seasons.first(where: { $0.seasonNumber == currentSeasonNum }) {
            if currentEpisodeNum < currentSeasonObj.episodeCount {
                return (currentSeasonNum, currentEpisodeNum + 1)
            }
        }
        
        // 2. Check next season
        let nextSeasonNum = currentSeasonNum + 1
        if seasons.contains(where: { $0.seasonNumber == nextSeasonNum }) {
            return (nextSeasonNum, 1)
        }
        
        return nil
    }
    
    func playNextEpisode() {
        guard let next = nextEpisodeInfo, let item = currentItem else { return }
        print("Playing Next Episode: S\(next.season):E\(next.episode)")
        
        AsyncTask {
            // Fetch next episode details to get the image
            var nextEpisodeImage: URL? = nil
            if let meta = try? await StremioService.shared.fetchMeta(type: "series", id: item.id) {
                // Find the episode
                if let vids = meta.episodes, let ep = vids.first(where: { $0.episodeNumber == next.episode && $0.seasonNumber == next.season }) {
                    nextEpisodeImage = ep.stillURL
                }
            }
            
            let finalImage = nextEpisodeImage
            
            await MainActor.run {
                self.play(item, season: next.season, episode: next.episode, episodeImage: finalImage)
            }
        }
    }
    
    // MARK: - Smart Preloading (Next Episode)
    
    private var hasPreloadedNext = false
    
    func resetPreloadState() {
        hasPreloadedNext = false
    }
    
    func preloadNextEpisodeIfNeeded() {
        guard !hasPreloadedNext, let next = nextEpisodeInfo, let item = currentItem else { return }
        
        hasPreloadedNext = true
        print("[PlayerManager] Smart Preloading Next Episode: S\(next.season):E\(next.episode)")
        
        AsyncTask {
            await StreamManager.shared.preloadStreams(for: item, season: next.season, episode: next.episode)
        }
    }
    
    // MARK: - Fallback Logic
    
    func tryNextStream() {
        guard let currentURL = currentStreamURL, !availableStreams.isEmpty else { return }
        
        // Find current stream index
        if let index = availableStreams.firstIndex(where: { $0.url == currentURL }) {
            let nextIndex = index + 1
            if nextIndex < availableStreams.count {
                let nextStream = availableStreams[nextIndex]
                print("[PlayerManager] Current stream failed. Trying next stream: \(nextStream.title) from \(nextStream.source)")
                
                DispatchQueue.main.async {
                    self.currentStreamURL = nextStream.url
                }
                return
            }
        }
        
        // If we can't find current stream (maybe it was a raw URL without being in list)
        // or we ran out of streams, try the first one if we haven't tried it yet?
        // For now, if we run out, we stop.
        print("[PlayerManager] No more streams to try.")
        DispatchQueue.main.async {
            self.errorMessage = "Unable to play video. Please try another source."
        }
    }
}
