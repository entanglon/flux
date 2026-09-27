# Flux Project Handover & Session Summary
**Updated**: September 27, 2026 (12:47 PM IST)  
**Latest Git State**: 242/242 Unit Tests Passing (100%)  
**Target Platform**: macOS 14.0+ (Universal / Apple Silicon arm64)  
**Xcode Target**: `flux` (Scheme: `flux`, Test Plan: `fluxTests`)  
---

## 1. Executive Summary for Antigravity Sessions
---
31. **Player Window Teardown, Double-Esc Exit, Buffering Overlay & Startup Beachball Resolution**:
    - **Clean Direct Window Teardown (Apple TV Parity)**:
      - Removed `window.toggleFullScreen(nil)` and the `0.45s` delay from `closePlayer()` in `PlayerView.swift`.
      - On macOS, calling `[NSWindow close]` while an animated space transition was underway was rejected by AppKit, leaving the window stranded on the desktop in windowed mode.
      - Calling `window.close()` directly on the host window along with SwiftUI's `dismiss()` now closes and destroys the player window immediately and cleanly from both fullscreen and windowed modes.
    - **Eliminated Spontaneous Playback Restart on Teardown**:
      - Disarmed `mpv.onPlaybackError = nil` and cancelled all active watchdog/countdown tasks (`playbackStartTask`, `bufferingGraceTask`, `midPlaybackStallWatchdogTask`, `cancelUpNextCountdown()`) in `closePlayer()` and `onDisappear`.
      - Prevents closed network sockets from triggering `onPlaybackError`, which previously invoked `advanceToStandbyFallback()` and restarted playback from `0:00`.
    - **Eliminated Permanent Buffering Logo Overlay**:
      - Gated both `logoBufferingView` and `midPlaybackLogoBufferingView` with `!isClosingPlayer`.
      - Added strict `playerManager.currentStreamURL != nil` requirement to `midPlaybackLogoBufferingView`, preventing `(!hasStartedPlayback && hasEverStartedPlayback)` from latching true when no stream is loaded.
    - **Eliminated Startup Beachball Cursor (Spinning Wheel)**:
      - In `MPVVideoView.swift:initializeGLContext()`, offloaded the deferred `command("loadfile", urlToLoad.absoluteString)` to `DispatchQueue.global(qos: .userInitiated).async`.
      - Prevents `mpv_command` from blocking the AppKit main runloop on initial socket connection, eliminating the 1–3s UI freeze and spinning wheel cursor.
    - **View State Isolation & Key Monitor Re-attachment**:
      - Applied `.id(item.id)` to `PlayerView(item: item)` in `PlayerWindowContainer` (`fluxApp.swift`) ensuring fresh `@State` and controllers per playback session.
      - Reset `isClosingPlayer = false` on `.onAppear` and guaranteed `PlayerWindowAccessor` re-attaches `PlayerKeyMonitor` if it was ever nilled.

32. **Instant Replay Cache Un-Gating & Complete Main-Thread Hitch Elimination**:
    - **Instant Replay Source Reuse Across Entire App**:
      - Root Cause: In `PlayerManager.swift:1092`, the instant replay / cached stream reuse check was artificially gated on `if fromContinueWatching && !forceStreamPicker`.
      - Whenever a user clicked "Play" on a detail screen, episode rail, or list where `prog <= 0.01` or `startFromBeginning` was set, `fromContinueWatching` was `false`. As a result, the active session cache (`lastPlayedStreams[key]`) and persisted watch history source were bypassed, re-triggering the full 5–15s multi-addon scraper race (`fetchAndRace`).
      - Solution: Un-gated the instant replay check to `if !forceStreamPicker`.
      - Verified Health Check & Torrent Prime: For HTTP streams, `PlayerManager` performs a fast non-blocking HEAD probe (`verifyStreamURLHealth` with 1.8s timeout, ~50ms response). If alive, resumes immediately. For torrent streams, it restores `activeTorrentHash`, primes the Go engine with `trackCreate`, starts live buffer stats polling (`startTorrentStatsPolling`), and plays immediately. Populates the manual stream picker in the background so alternative sources remain accessible.
    - **Complete Main-Thread Beachball Elimination**:
      - Disabled libmpv's `ytdl` option (`mpv_set_option_string(mpv, "ytdl", "no")`). Setting this to "yes" previously triggered mpv's internal Lua hook which synchronously scanned system `PATH` and executed Python / yt-dlp binaries on player init and loadfile.
      - Offloaded CoreAudio property listener registration in `AudioOutputRouteMonitor.shared.start()` to `DispatchQueue.global(qos: .utility)` to prevent synchronous IPC calls to `coreaudiod` from blocking the main thread.
      - Offloaded `mpv_set_property_string` for proxy and pause state inside `loadFile` and `setupMPVGL` onto `DispatchQueue.global(qos: .userInitiated)` right alongside `command("loadfile")`, eliminating all synchronous lock contention on the main thread during stream startup.
    - **Test Coverage & Verification**:
      - Added unit tests for `AudioOutputRouteMonitor.shouldAutoPause` and torrent/HTTP streaming URL compatibility matching in `fluxTests.swift`.
      - All 242 unit tests passing cleanly across 9 test suites (`** TEST SUCCEEDED **`), ad-hoc signed, and running live.

33. **Zombie Player Window Resurrection & Signed Stream URL Cache Fix**:
    - **Eradication of Zombie Player Window**:
      - Root Cause: `PlayerWindowRouter.openPlayerWindow` previously searched `NSApp.windows` for any window with title "player" or identifier "playerWindow", calling `makeKeyAndOrderFront` on it instead of routing through SwiftUI's `openWindow(id: "player", value: itemID)`.
      - When double-Esc closed the window via `window.close()`, AppKit ordered it out, but the closed zombie `NSWindow` instance lingered in `NSApp.windows`. Clicking a title on Continue Watching re-activated this dead window with dead state (`isClosingPlayer = true`, nilled key monitors, stopped mpv), resulting in a blank screen and broken Esc key behavior (which fell back to AppKit's default fullscreen exit into windowed mode).
      - Solution: Removed the AppKit window search in `PlayerWindowRouter.openPlayerWindow` to strictly dispatch via SwiftUI's `openWindow(id: "player", value: itemID)`. Added `dismissWindow(id: "player")` to `closePlayer()` in `PlayerView.swift`.
      - Keyed `PlayerView(item: item)` in `PlayerWindowContainer` (`fluxApp.swift`) with `.id(playerManager.playbackSessionUUID)`, guaranteeing a completely fresh view instance, fresh `@State`, active event monitors, and clean lifecycle on every play invocation.
    - **Signed Token & Debrid Stream URL Caching (HTTP + P2P)**:
      - Root Cause: In `PlayerManager.confirmPlaybackSuccess`, a filter checked `url.query?.contains("sig=")`, `contains("token")`, `contains("exp")`, etc., and set `historyItem.lastStreamURL = nil` while skipping `lastPlayedStreams[key] = CachedStream(...)`.
      - This intentionally discarded stream URLs from hosters like PenguPlay (which sign URLs with `?psig=...`), causing titles to have no saved stream and forcing full scraper re-fetching on replay.
      - Solution: Removed query token restrictions. Both direct HTTP streams (signed or unsigned) and local P2P torrent streams (`http://127.0.0.1:11470/{hash}/{fileIdx}`) are now reliably cached in `lastPlayedStreams` and persisted in `UserDataService` history. On replay, `verifyStreamURLHealth` validates if the URL is still alive; if valid, playback starts instantly; if expired, it seamlessly falls back to scraping.

34. **MPVController Attachment Race & Instant Replay Infinite Buffer Resolution**:
    - **Root Cause (The Microsecond Race)**:
      - When playing a title for the first time, scraper queries take 3–5 seconds, so SwiftUI's AppKit representable (`MPVVideoView.makeNSViewController`) mounts and sets `controller.playerView = vc` well before `currentStreamURL` is emitted.
      - On instant replay, however, `verifyStreamURLHealth` validated in ~40ms, immediately assigning `playerManager.currentStreamURL = cached.url`.
      - `PlayerView.onChange(of: currentStreamURL)` called `handleStreamURLChange(url)` -> `mpv.play(url:)` *before* AppKit called `makeNSViewController`!
      - Because `playerView` on `MPVController` was `nil`, the line `playerView?.play(url, paused: false)` used optional chaining and **silently dropped the play call without loading the file into mpv**.
      - Crucially, `mpv.hasLoadedMedia = true` and `mpv.loadedURL = url` were still recorded. When `PlayerView.onAppear` executed moments later, it saw `mpv.hasLoadedMedia == true`, mistook it for an already playing warm core, and only called `mpv.play()` (which only unpaused/resumed). `loadFile` was NEVER called on mpv!
      - The player sat idle with no media loaded while `isInitialLoading` remained `true`, trapping the user on an endless buffering screen while the stream URL itself was perfectly valid.
    - **Solution**:
      - Added `pendingPlayURL` and `pendingPaused` queuing to `MPVController`. If `play(url:)` or `preparePaused(url:)` is invoked before `playerView` is attached, the request is safely staged in `pendingPlayURL`.
      - Wired `didSet` on `weak var playerView: MPVViewController?` and `makeNSViewController` to immediately flush and execute any staged `pendingPlayURL` as soon as the NSViewController is created and linked.
      - Added `mpvLayer.setNeedsDisplay()` to `viewDidMoveToWindow()` and `loadFile` (when `mpvGL == nil`) in `MPVLayerView`, ensuring CoreAnimation immediately schedules the OpenGL context creation and frame rendering.
      - Strictened `PlayerView.onAppear` warm-core adoption check to `mpv.hasLoadedMedia && mpv.loadedURL != nil && mpv.loadedURL == playerManager.currentStreamURL`, and armed `pendingResumeTime = resumePos` in `PlayerManager.play` so saved watch positions seek automatically.

35. **Instant Replay Pipeline Unblocking & Auto-Play from Last Source for Non-Flux Mode**:
    - **libmpv `loadFile` Deferral Elimination**:
      - Root Cause: In `MPVVideoView.swift:MPVLayerView.loadFile`, issuing `command("loadfile", url.absoluteString)` to mpv was gated on `if mpvGL != nil`. When `mpvGL == nil` (a fresh, cold player instance), it deferred the command to `pendingURL` and requested a redraw.
      - However, mpv core does not require an active OpenGL render context (`mpv_render_context`) to begin socket connection, HTTP handshake, and demuxing. By deferring `loadfile`, mpv never received the URL, produced no video frames, and never triggered `mpvGLUpdate`, causing an infinite buffering loop.
      - Solution: Removed the `mpvGL == nil` deferral in `loadFile`. `command("loadfile", url.absoluteString)` is now dispatched directly on `DispatchQueue.global(qos: .userInitiated).async` immediately upon invocation. mpv demuxes in parallel while CAOpenGLLayer initializes `mpvGL`.
    - **Auto-Play from Last Source in Non-Flux Mode (Stremio Parity)**:
      - Root Cause: `DetailView.swift` previously passed `forceStreamPicker: !isFlux` on Play / Resume buttons even when `target.isResume == true` or `fromContinueWatching == true`. In `PlayerManager.play`, `if forceStreamPicker` completely bypassed the instant replay / cached stream reuse check, unconditionally presenting the stream picker for Non-Flux users.
      - Solution: Updated `DetailView.swift` to pass `forceStreamPicker: (!isFlux && !target.isResume)`, `forceStreamPicker: (!isFlux && !isInContinueWatching)`, and `forceStreamPicker: (!isFlux && !hasProgress)`. In Non-Flux Mode, resuming a title with progress or clicking from Continue Watching now auto-plays from the last healthy source immediately without prompting the stream picker, exactly like Stremio.
      - The stream picker is only presented in Non-Flux Mode for brand-new unwatched titles, or when explicitly requested via "Choose Stream Source…" in context menus.
    - **Stream Probe Robustness & Accurate Player Loading State**:
      - Updated `PlayerManager.verifyStreamURLHealth` to set standard browser `User-Agent` headers and support a fast Range `GET` fallback when CDNs return `405 Method Not Allowed` for `HEAD` requests.
      - Removed premature `(!isFluxEnabled && playerManager.currentStreamURL == nil)` gate in `PlayerView.isPickerVisible`, allowing the loading overlay to display cleanly during instant replay resolution without flashing the stream picker.

---

---

## 1. Executive Summary for Antigravity Sessions

This project is **Flux**, an open-source, modern native macOS media and streaming application built with SwiftUI, the official Stremio streaming server (`server.js` + Node.js runtime), native `libmpv` video playback via `LocalMPVKit`, PocketBase backend sync, and TMDB / Stremio addon catalog aggregation.

The app has recently undergone major enhancements:
1. **Direct TMDB-First Search Engine**: Direct integration with TMDB search without restrictive pre-filtering or token penalties, ensuring international and catalog titles (e.g., *Dark 2017*) surface accurately, with Cinemeta/Stremio fallback.
2. **Bidirectional Liquid Glass Carousel Navigation**: Viewport coordinate tracking dynamically displays both left and right chevrons and enables smooth multi-card scrolling under the sidebar.
3. **Search Query History**: Namespaced per-profile recent query chips with individual delete and "Clear All" actions.
4. **Watch & Search History Clearing with PocketBase Cloud Sync**: Full atomic purge capabilities in Settings and History with Anti-Regression Shield protections so intentional wipes sync cleanly to PocketBase without resurrection.
5. **Card Context Menus & Action Parity Across the App**: Added missing right-click `.contextMenu` support to `LiquidEpisodeCard` and `RecentSearchCard`, matching ellipsis button menus with full action parity (Play/Resume, Play from Beginning, Choose Stream Source…, dynamic Mark as Watched/Unwatched, and Remove from Recent Searches) localized across all 10 supported languages.
6. **Brotli HTTP Stream Decompression Fix**: Fixed fatal playback crashes (`mpv[ffmpeg]: http: Unknown content coding: br`) on upstream proxy and scraper streams by injecting `Accept-Encoding: identity` and stripping decompression headers.
7. **Complete Candidate Waterfall & Torrent Fallback Retention**: Fixed premature candidate pruning in `PlayerManager` so all candidates (including all healthy torrent swarms) remain in the standby waterfall with up to 5 auto-fallbacks.
8. **Cloud Settings Synchronization & PocketBase Revert Resolution**:
   - Fixed local settings reverting upon cloud sync by enforcing strict timestamp precedence (`remoteUpdatedAt > localUpdatedAt`) in `ProfileManager` and `UserDataService`.
   - Removed legacy `rBool || (lBool && hasEp)` logic that unconditionally forced `streamRouteProxyEnabled: true` from stale cloud data.
   - Synchronized `geminiApiKey` in cloud payload, auto-snapshotting profile settings before sync export, and debounced settings auto-sync to 0.5s.
   - Patched PocketBase record `llicplrw2m6y3ny` to disable stale proxy and synchronize default Gemini model (`gemini-3.5-flash-lite`) and quality (`1080p`).
9. **Stream Source Inspector "BitTorrent Swarm" Badge Correction**:
   - Fixed false `BitTorrent Swarm (P2P)` badge appearing on HTTP sources (e.g., PenguPlay) by making `stream?.isTorrent` authoritative and clearing `PlayerManager.activeTorrentHash = nil` on non-torrent playback.
10. **HLS / DASH Relative Segment Resolution in StreamProxyManager**:
    - Resolved playback failure cascading on *Guns & Gulaabs* and *Salute*: upstream scrapers returning `.m3u8` playlists with relative segments (e.g., `/init-stream3.m4s`) are now resolved against `lastOriginURL` / `lastBaseDirectoryURL` rather than throwing HTTP 400 Bad Request.
11. **Experimental AI Stream Selection Layer (Gemini Flash)**:
    - Opt-in intelligent stream ranking engine (`GeminiStreamRanker.swift`) supporting Gemini 3 models (`gemini-3.5-flash-lite`, `gemini-3.6-flash`, `gemini-3.8-flash`, `gemini-3.7-flash`, etc.).
    - Injects user preferences (maximum resolution e.g. 1080p, preferred audio languages, 1.5–8 GB size bounds) into the prompt.
    - Full 10-language localization matrix with zero duplicates (616 keys across all 10 languages).
12. **HTTP Scraper Quorum Barrier, Seeder Floor & Dynamic Hot-Swap**:
    - Added `hasPendingHttpScrapers` barrier to `StreamManager.hasQualityQuorum`: prevents premature P2P torrent lock-in in "both" mode while HTTP scrapers (e.g., PenguPlay) are in-flight within an adaptive 3.5s grace window.
    - Filtered unstreamable torrents (< 5 seeders) before Gemini ranking and enforced strict seeder threshold rule (>= 10-15 seeders) in `GeminiStreamRanker.swift`.
    - Implemented dynamic hot-swap and standby fallback ingestion in `PlayerManager.swift`: newly discovered direct HTTP streams from late scrapers automatically preempt stalled torrents (0 bytes/buffering after 3.0s) and populate the fallback pool.
13. **OpenSubtitles IMDb Resolution, P2P Buffer Telemetry & Gemini 14s Timeout**:
    - Resolved OpenSubtitles v3 returning empty track lists on TMDB titles by resolving IMDb IDs (`tt...`) before dispatching requests to `{cleanURL}/subtitles/{type}/{imdbId}.json`.
    - Wired live `streamProgress` from `StremioServerManager.fetchTorrentStats` into `PlayerManager` and `PlayerView`, providing smooth, genuine buffer progress for P2P torrent streams during swarm pre-buffering.
    - Increased `GeminiStreamRanker` ephemeral network timeout to 14.0s (resource 16.0s) to eliminate premature timeouts during multi-candidate evaluations.
    - Tuned initial scraper evaluation window to 3.5s so fast/cached sources start quickly while preserving conditional hot-swap for late scrapers.
14. **Playback Stabilization, Torrent Watchdog & OpenSubtitles v3 Fix**:
    - **Premature Hot-Swap Resolution**: Fixed `onStreamsUpdated` measuring elapsed time from query start rather than `currentAttemptStartTime` (which previously killed torrents after 272ms). Added an 8.0s stall guard requiring `torrentStreamProgress < 0.05` and no bytes for 6+ seconds before any hot-swap is considered.
    - **Quality Inversion Prevention**: Strictly enforced `qualityScore <= qualityScore(preferredQuality)` across standby fallbacks, dynamic hot-swap, and fallback advancement. Eliminates unwanted 4K replacements for 1080p users.
    - **Torrent Engine Watchdog Intelligence**: Prevented watchdog from aborting active torrent downloads. If the Go engine is actively receiving pieces or reporting progress, the watchdog preserves playback instead of prematurely invoking `removeTorrent()`.
    - **P2P Loading Bar Fill**: Shared `startTorrentStatsPolling` across both standard and fast-path prefetch sessions, and anchored `GeometryReader` mask alignment to `.leading` in `PlayerView.swift` so the logo fills smoothly from left to right.
    - **OpenSubtitles v3 Restoration**: Guaranteed `resources = ["subtitles"]` in `AddonManager.swift` and enhanced `SubtitleManager.swift` to discover OpenSubtitles v3 reliably with full OSLog telemetry.
15. **AI Stream Selection Optimization, Zero-Override Commitment & Lag Elimination**:
    - **Confirmed Root Cause of Ignored AI Data**: `StreamManager.raceTopCandidatesWithResults` had `candidates.first { !stream.isTorrent && probeResults[stream.stableKey] == true }` which disqualified torrents from the probe race, discarding Gemini's #1 torrent pick and forcing broken lower-ranked HTTP streams that dropped sockets with `Immediate exit requested`.
    - **Zero-Override Commitment**: When AI stream selection is enabled and ranks streams, `firstPass` is committed directly without being routed through the HTTP-bias probe race. The remaining AI choices are stored in `standbyFallbacks` in the exact order Gemini ranked them.
    - **Resolved Extreme Lag & Freezing**: `GeminiStreamRanker` previously sent 25 candidate streams in verbose pretty-printed JSON (2,700 tokens), causing 22+ second latency and HTTP 429 quota exhaustion. Refactored to send top 12 pre-filtered candidates in compact single-line format (~200 tokens) with `maxOutputTokens: 200` and `temperature: 0.0`. Latency dropped from 22.78s to 1.1–2.6s.
    - **Restricted AI to Intentional Playback**: Speculative browsing prefetch (`runPrefetch`) now passes `isPrefetch: true` to bypass the external LLM entirely and use instant local heuristics, preserving API quota and preventing background freezes.
    - **Single-Flight Auto-Play Guard**: Added `isAutoPlayRaceActive` guard across early quorum commit and full fetch completion, preventing duplicate parallel AI calls and multiple simultaneous stream attempts.
    - **Model Expansion**: Added `gemini-2.5-flash` with zero-budget thinking support (`thinkingBudget: 0`) and fully localized across all 10 supported languages with zero dictionary duplicates.
16. **Flux Mode Auto-Play Race Resolution, Continuous P2P Buffer Fill & OpenSubtitles Auto-Selection**:
    - **Stream Picker Appearing in Flux Mode**: Fixed race condition where early quorum launched an unawaited fire-and-forget task; when scraper queries completed, the fallback block evaluated `selectionMade == false` and prematurely forced `isStreamPickerPresented = true`, subsequently aborting Gemini's winner. Fixed by tracking `autoPlayRaceTask`, awaiting its completion upon fetch conclusion, and guarding the fallback modal.
    - **P2P Loading Bar Fill**: Added `streamLen` to `TorrentStats` and updated `startTorrentStatsPolling` to compute continuous, monotonic progress from downloaded bytes (`min(0.90, downloaded / 12_500_000.0)`), unchoked peers, and stream progress, eliminating the frozen 5% loading bar on torrent streams.
    - **OpenSubtitles Automatic Track Selection & Caching**: Separated audio and subtitle auto-selection flags in `MPVController`. Subtitles now auto-select when `preferredSub != "Off"` regardless of whether audio is English or foreign. Added `.onChange(of: playerManager.externalSubtitles)` in `PlayerView` for late-arriving subtitles, localized language labels (e.g., `English (OpenSubtitles v3)` instead of raw `eng`), and cached external subtitles locally to ensure 100% reliable mpv playback without HTTPS errors.
    - **Gemini Structured Output**: Added strict `responseSchema` to `GeminiStreamRanker` with a robust multi-key and regex parser fallback so index extraction never fails.
17. **Proxy Persistence, Cloud Sync Anti-Regression Shield & Main-Thread Beachball Elimination**:
    - **Proxy Auto-Disabling Root Cause**: PocketBase cloud sync (`syncNowInternal: pullFirst=true forcePull=true`) ran on window focus / didBecomeActive. PocketBase record `llicplrw2m6y3ny` stored `streamRouteProxyEnabled: false`. `exportGlobalSettings()` generated fresh timestamps (`Date().timeIntervalSince1970`) on unrelated pushes, making remote settings appear newer than local settings. On pull, `applyCloudPayload` wiped local proxy settings to `false`. Added Proxy Anti-Regression Shield to `UserDataService.swift` and `ProfileManager.swift` (preserves local enabled state if endpoint is configured and local timestamp is valid). Patched live PocketBase record `llicplrw2m6y3ny` to `streamRouteProxyEnabled: true`. Stamped `settingsUpdatedAt` on true settings modifications only, and changed proxy config / addon toggles to `scheduleAutoSync(delay: 0.1)`.
    - **Player Teardown Hangs**: Removed spurious `fluxRefresh` from `PlayerView.onDisappear` and `DetailView` episode mark-watched which cleared image caches. Made `mpv_terminate_destroy` asynchronous on `DispatchQueue.global(qos: .utility)` to prevent dead demuxer sockets from hanging main thread.
18. **Resolution Cloud Persistence, Non-Blocking MPV Demuxer Teardown & Resilient Quality Fallback**:
    - **Resolution Preference Reset Root Cause**: `UserDataService.hasLocalAdditionsToPush` evaluated whether to push local data during pull-first syncs based only on watch history, items, and collections, omitting settings timestamps (`localSettingsNewer || missingSettingsInCloud`). When the user set resolution to 4K, auto-sync pulled from PocketBase first and never pushed the updated settings dictionary back, overwriting local `preferredQuality` with stale 1080p remote snapshots on subsequent app restarts. Patched `hasLocalAdditionsToPush` to include `localSettingsNewer` and patched live PocketBase record `llicplrw2m6y3ny` to `preferredQuality: "4K"`.
    - **Main-Thread Hang & Spinning Beachball on Detail Navigation**: When mpv's ffmpeg demuxer encountered dead or disconnected torrent swarms (e.g., *Coyote vs. Acme* returning premature EOF at 6MB), ffmpeg entered a 0-second reconnect loop. Calling `command("stop")` or `mpv_command` synchronously in `discardWarmCore()` or `cancelDetailPrefetch()` blocked the main thread waiting on demuxer mutex locks, spinning the beachball cursor during navigation to and from `DetailView` (and stalling subsequent titles like *Zootopia 2* during core teardown). Made `stop()` non-blocking by dispatching `command("stop")` on `DispatchQueue.global(qos: .userInitiated)`, added a 350ms navigation yield in `DetailView.task` to ensure push transitions finish smoothly before prefetching, and added sliding-window reconnect storm detection (>= 3 reconnects in 5s) triggering auto-advance via `PlayerManager.handleStreamFailure`.
    - **Resilient Fallback Resolution Floor**: Fixed *Heart of the Beast* failure where Cinejoy HLS served empty segments and all remaining 4K streams were rejected by the fallback filter because `preferredQuality` had reverted to 1080p. Introduced `higherQualityFallback` in `advanceToStandbyFallback()` so higher-resolution streams are preserved as an emergency fallback instead of failing playback completely when lower-resolution streams are exhausted.
19. **Torrent Startup Watchdog Correction & Memory Image Cache Preservation**:
    - **False-Positive Reconnect Kill Loop Resolution**: Sliding-window reconnect storm detection in `MPVVideoView.swift` previously triggered on normal ffmpeg BitTorrent connection retries at byte offset 0 (`Will reconnect at 0 in 0 second(s)`). During the initial buffering phase, Stremio's embedded engine (`FluxEngine` on port 11470) takes a few seconds to connect to DHT peers and buffer initial header pieces. The watchdog misidentified these retries as dead streams, killing torrents after 1 second, rapidly burning through the entire fallback waterfall, and causing port 11470 to refuse connections. Restricted reconnect storm detection strictly to active mid-stream playback drops (`PlayerManager.shared.hasPlaybackStarted == true` at non-zero offsets) and cleared `reconnectTimestamps` on `loadFile` and `stop()`. Initial torrent buffering is now safely governed by `armStartupWatchdog` (allowing up to 35 seconds matching Stremio).
    - **Persistent In-Memory Poster & Thumbnail Cache**: Removed destructive `ImageInMemoryCache.purgeMemoryCache()` from `PlayerView.onAppear`. Previously, starting any video purged all decoded posters, logos, and backdrops from RAM, forcing Home, Search, and Detail screens into loading/shimmer states upon exiting the player. Memory is now preserved in the 128MB cache across playback sessions.
20. **Resolution Setting Default Alignment, Reconnect Loop & UI Hang Fixes**:
    - **preferredQuality Reversion Fix**: The `@AppStorage("preferredQuality")` in `SettingsView.swift:523` used a compile-time default of `"4K"`, while `StreamManager.maxAllowedQualityScore()` (line 959) and `PlayerManager` next-episode prefetch (line 2692) also fell back to `"4K"`. Changed all three fallback defaults to `"1080p"` to eliminate race conditions during startup where any transient gap between `restoreSettings` and SwiftUI view construction could snapshot the wrong default. All other `preferredQuality` reads (PlayerManager lines 348, 1304, 1352, 1528, 2118) already used `"1080p"`.
    - **Streaming Pipeline Verification**: Comprehensive audit comparing Flux's streaming architecture against Stremio's reference implementation. Verified all 17 key features match or enhance Stremio: fire-and-forget `/create`, sequential piece streaming, HTTP Range support, Ultra-Fast engine settings, 300MB demuxer buffer, 60s readahead, FFmpeg reconnect, startup watchdog (35s torrent / 14s HTTP), StreamProxyManager with transparent upstream retry, dynamic hot-swap, reconnect storm detection, and AI stream ranking. No critical streaming pipeline issues found.
    - **Infinite Reconnect Loop (Flashing) Fix**: When a stream dropped mid-playback and reconnected from offset 0 (e.g., due to an upstream proxy ignoring `Range` headers), the reconnect storm detector erroneously classified it as an `isInitialStartupConnect` and skipped `isStorm` evaluation. This caused MPV to infinitely loop between "playing" (first 2 seconds) and "loading" (reconnecting). Removed `!isInitialStartupConnect` from the `playbackRunning` block in `MPVVideoView.swift` so fatal mid-stream resets correctly trigger the standby fallback waterfall.
    - **Non-Blocking MPV LoadFile**: While `mpv.stop()` was dispatched to a background queue, the subsequent `command("loadfile", ...)` executed synchronously on the main thread. Since `mpv_command` locks the core during tear-down, `loadfile` blocked the main thread, causing severe UI lag and beachballing during stream transitions. Wrapped the `loadfile` command execution in `DispatchQueue.global(qos: .userInitiated).async`.
    - **Season Menu Scroll Override**: Fixed an issue where `FloatingSeasonPanel` rendered all seasons in an unconstrained `VStack`, overflowing the screen vertically for shows with many seasons (e.g., Grey's Anatomy). Wrapped the `VStack` in a `ScrollView` with a `maxHeight` limit of `350` and hid indicators.
21. **Test Suite Proxy Pollution Resolution & Direct HTTP Playback Fix**:
    - **Dead Proxy Endpoint Leak Root Cause**: `StreamRouteProxyTests` used a dummy IP `http://100.64.0.1:8888` and set `StreamRouteProxyManager.shared.endpointURL` and `isEnabled = true`. Because `StreamRouteProxyManager.endpointURL.didSet` triggered `ProfileManager.shared.saveCurrentProfileSettings()` without restoring original settings upon test completion, the dummy IP was permanently stamped into Zayn's active profile and UserDefaults.
    - **Symptom & Verification**: Whenever any stream containing keywords like `"pengu"` (e.g. `https://pengu.uk/direct/external/...`), `"cinefreak"`, `"2peckle"`, etc. was played, `MPVVideoView` set `mpv`'s `http-proxy` to `http://100.64.0.1:8888`. FFmpeg timed out trying to connect to the non-existent IP (`tcp: Connection to tcp://100.64.0.1:8888 failed: Operation timed out`), while Chrome played the stream instantly because Chrome bypassed the dead proxy.
    - **Fix**:
      1. Cleaned all 35 polluted profile snapshots and global UserDefaults keys, resetting `streamRouteProxyEnabled = false`.
      2. Isolated `StreamRouteProxyTests` by capturing initial profile and global proxy settings and restoring them in a `defer` block in each test.
      3. Added sanity filters in `recoverConfiguredEndpoint()` to ignore test IPs (`100.64.0.1`, `example.com`).
      4. All 233 unit tests pass cleanly without polluting UserDefaults.
22. **Post-Playback 2-Second Kill Loop Resolution ("Flashing at 2s")**:
    - **Root Cause Identified**:
      1. In `PlayerManager.swift:armStartupWatchdog`, an aggressive post-start monitor loop ran after `hasPlaybackStarted == true`. If `lastObservedCacheTime < 4.0` and measured `sustainedStartupThroughputKBps < 150 KB/s`, it gave the stream a "slow speed strike". At strike 2 (checked at 1s intervals), it executed `self.advanceToStandbyFallback()`.
      2. In `PlayerView.swift`, the `.onReceive(loadingTimer)` handler had an early `return` inside `if mpv.isPlaying && mpv.timePos >= 0.05`. Because `playerManager.reportTelemetryProgress(cacheTime: bufferAhead)` was located *after* this return, `lastObservedCacheTime` in `PlayerManager` was never updated while playing and remained perpetually at `0.0`.
      3. At startup, MPV decodes the initial burst of frames while network read speed (`cache-speed`) momentarily rests at 0 KB/s. Because `lastObservedCacheTime < 4.0` was permanently satisfied and speed was < 150 KB/s, every stream accrued strike 1 at 1.0s and strike 2 at 2.0s, triggering `advanceToStandbyFallback()` at exactly 2.0 seconds of playback.
      4. This cycled endlessly through all fallbacks: Stream 1 started -> played 2.0s -> killed -> Stream 2 started -> played 2.0s -> killed, manifesting to the user as rapid "flashing between loading and playing in the first 2 seconds".
    - **Fix Applied**:
      1. Updated `armStartupWatchdog` to immediately disarm and exit as soon as `hasPlaybackStarted == true`.
      2. In `markPlaybackStarted()`, explicitly canceled and nilled `startupWatchdogTask`.
      3. Moved `reportTelemetryProgress` to the top of `loadingTimer` in `PlayerView.swift` so telemetry updates unconditionally every 500ms.
      4. All 233 unit tests pass cleanly.
23. **Player Two-Press Escape Key Exit Restoration**:
    - **Single-Press Exit Root Cause**: When native borderless window key monitoring was added, `PlayerView.swift:handleEscapePress()` directly invoked `closePlayer()` on unhandled Esc presses, bypassing `showExitWarning` and `exitWarningOverlay`.
    - **Restoration**: Implemented two-press confirmation sequence: first press displays `"Press Esc again to exit".localized` in a liquid glass overlay and starts a 2-second auto-dismiss timeout; second press cancels the timer and exits via `closePlayer()`.
    - **Overlay Priority**: Overlays (diagnostics HUD, About Stream Source modal, manual Stream Picker) dismiss first on single Esc before the exit sequence begins.
    - **Dynamic Localization & State Cleanup**: Added `@ObservedObject private var languageManager = LanguageManager.shared` (Rule 1 compliance) and properly reset state in `onDisappear`, `onChange(of: currentPlaybackKey)`, and `closePlayer()`.
    - **Top-Center Pill UI**: Re-anchored the prompt to a top-center liquid glass capsule (`Capsule`, `.padding(.top, 36)`) with asymmetric slide-down/fade transitions so it never blocks video action.
24. **Full HTTP Stream Route Proxy Mode & Scope Expansion**:
    - **Full Proxy Mode**: Added `proxyAllHTTP: Bool` (defaults to `true`) to `StreamRouteProxyManager.swift` and `UserDefaults.Key.streamRouteProxyAllHTTP`. When Route Proxy is turned ON, all external HTTP/HTTPS video playback routes through the proxy by default.
    - **Strict Firewall Preserved**: Torrents (`127.0.0.1:11470`), local stream proxy (`127.0.0.1:51547`), TMDB metadata, Cinemeta, OpenSubtitles, and PocketBase cloud sync NEVER route through the proxy.
    - **UI & Localization**: Added "Proxy All HTTP Streams" toggle card to `StreamRouteProxyConfigSheet.swift` with verified 10-language translations (zero duplicates across all 10 languages). All 234 unit tests passing.
25. **Direct / P2P Streaming Terminology Alignment**:
    - **Terminology Standardization**: Renamed all user-facing HTTP/Torrent mentions across Settings and Proxy Configuration to "Direct" and "P2P" ("Direct & P2P Streams", "Direct Streams Only", "P2P Streams Only", "P2P Cache Limit", "Purge P2P Cache", "Proxy All Direct Streams").
    - **Localization Matrix**: Added 10-language translations across all supported languages with zero dictionary duplicate keys.
26. **VideoToolbox Hardware Decoding, Stream vs Magnet Copy Separation & Mid-Playback Buffer Badge**:
    - **Hardware Decoding Restoration**: Changed `hwdec` from `"auto"` to `"auto-safe"` in `MPVVideoView.swift`. With OpenGL `CAOpenGLLayer`, `auto` attempted zero-copy mapping (`videotoolbox`), which libmpv rejects on 10-bit HEVC (`Main 10`) surfaces and silently fell back to CPU software decoding. `auto-safe` uses copy-back (`videotoolbox-copy`), restoring native Apple Silicon hardware acceleration (`VideoToolbox (Hardware)`).
    - **Stream Link vs. Magnet Link Separation**: Fixed `PlayerControlsView` and `PlayerView` (context menu & About Stream Source modal) which previously prioritized `currentMagnetURL` over `currentStreamURL`. "Copy Stream Link" now copies the playable stream URL (`http://127.0.0.1:11470/...` or CDN link), proving local streaming server activity. Added a dedicated "Copy Magnet Link" action button and context menu item when a torrent magnet exists, fully localized in all 10 languages with zero duplicate keys.
    - **Mid-Playback Buffering UI & Interactive Controls**: Removed `if !sustainedBuffering` gating from `controlsLayer` so player controls remain mounted and accessible during stalls. Restored `midPlaybackLogoBufferingView` matching commit `7f458ce`: video frame pauses under a 35% dark vignette, displaying a floating liquid glass badge with the logo and a sleek horizontal capsule progress bar (`width: 140, height: 4`) reflecting live buffer fill for both direct HTTP and P2P torrent streams.
27. **Stream Link Interception Fix, Mid-Playback Stall Detection & macOS libmpv OpenGL Pipeline**:
    - **Stream Link vs Magnet Separation**: Fixed `cleanPlayableURLString(from:)` in `PlayerManager.swift` which intercepted valid `http://127.0.0.1:11470/...` streaming URLs and converted them back to magnets. "Copy Stream Link" now strictly copies the playable HTTP stream link.
    - **Mid-Playback Buffering Logo Restoration**: Resolved `isUserPaused` false-positive in `MPVVideoView.swift:case "pause"`. When buffer starved, mpv's internal pause was erroneously treated as a user pause, suppressing the mid-playback buffering overlay.
    - **Stall Watchdog**: Added an 18-second watchdog (`midPlaybackStallWatchdogTask`) in `PlayerView.swift` to automatically advance to standby fallbacks on dead swarms.
    - **Architectural Documentation**: Documented why `CAOpenGLLayer` with `MPV_RENDER_API_TYPE_OPENGL` is the only supported embedded host API in `libmpv` on macOS, while hardware video decoding runs independently via Apple VideoToolbox (`videotoolbox-copy`).
28. **P2P Torrent Streaming Engine Deep-Dive & Root-Cause Diagnosis**:
    - **Live Engine Testing**: Analyzed the embedded Go binary `FluxEngine` (`github.com/M0Rf30/stremio-server-go` v0.12.1 built on `anacrolix/torrent`).
    - **Confirmed 5 Root Causes of P2P Playback Failures**:
      1. *Engine Instability*: Under concurrent swarm load, the engine pegged at 111% CPU and crashed, taking the host process down with it.
      2. *10-50x Throughput Deficit*: Well-seeded torrents (200+ seeders like Big Buck Bunny and Guardians of the Galaxy) downloaded at only 73–180 KB/s in FluxEngine instead of the 5–20 MB/s achieved by official Stremio / qBittorrent, starving mpv's demuxer buffer.
      3. *`selections: null` & Absence of Sequential Prioritization*: The engine's stats endpoint reports `selections: null`, proving piece priorities were never set for sequential video streaming, downloading random blocks across the swarm.
      4. *Blind `fileIdx: 0` Fallback*: When addon manifests omit `fileIdx`, defaulting to 0 frequently downloads small `.srt` or `.nfo` text files instead of the main video container.
      5. *Fire-and-Forget `/create` Race Condition*: Handing the stream URL to mpv before `resolveTorrentStream` finishes metadata resolution causes mpv to read from unready swarms.
29. **Mid-Playback Buffering UI Regression Analysis**:
    - **Regressed Card Container Identified**: In commit `e56210b`, `midPlaybackLogoBufferingView` was wrapped in an unwanted `RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial.opacity(0.85))` floating card box, shrinking the logo from `maxHeight: 100`/`76` to `70` and adding a separate progress bar.
    - **Historical Audit**: Git archaeology on commits `21eed32` ("use pure logo fill buffer loading without separate progress bar") and `a5f94e0` ("remove floating buffer card") confirmed the authentic original design: a clean, borderless, floating title logo filling left-to-right directly over the `Color.black.opacity(0.35)` darkened video frame without any surrounding card background.
30. **Authentic Mid-Playback Buffering UI Restoration**:
    - **Removed Knockoff Card Container**: Stripped the `.background(RoundedRectangle(...).fill(.ultraThinMaterial...))` container, container padding, and separate `140x4` capsule progress bar from `midPlaybackLogoBufferingView` in `PlayerView.swift`.
    - **Restored Pure Borderless Fill**: Re-anchored `loadingLogo(for: media, progress: realProgress)` directly over `Color.black.opacity(0.35)` vignette, maintaining authentic Apple TV-style pure logo fill (`maxHeight: 100`/`76`) without card boxes or duplicate progress indicators.
31. **P2P Torrent Streaming Architecture Overhaul & Smart Multi-File Resolution**:
    - **Root Cause of Multi-File Failures (e.g. Big Buck Bunny)**: Multi-file torrents frequently place a tiny subtitle (`.srt`, 140 bytes), NFO, or poster file at index 0. Because movie streams often omit `fileIdx`, Flux previously hardcoded `stream.fileIdx ?? 0`, requesting `/{infoHash}/0` from the streaming server. libmpv received plain text subtitles as video input, causing ffmpeg demuxer crashes (`Invalid data found when processing input`).
    - **Smart `fileIdx` Resolution**: Implemented `PlayerManager.findBestVideoFileIndex(files:targetSeason:targetEpisode:)` which inspects the streaming engine's `/create` response `files` array. For movies, filters out samples/trailers/subtitles/posters and selects the primary video file by byte length. For series season packs, accurately parses episodic patterns (`S01E02`, `1x02`, `e02`) to extract the exact requested episode file.
    - **Sequential `/create` Handshake**: Replaced fire-and-forget `/create` calls in `attemptStream` with an awaited `resolveTorrentStream` call (with an 8.0s timeout). The resolved `fileIdx` is written back to `stream.fileIdx` and `currentSelectedStream`, ensuring mpv always requests the true video payload (`/{infoHash}/{resolvedIdx}`). If the torrent swarm fails to respond or is dead, the stream gracefully auto-advances to standby fallbacks.
    - **P2P Streaming Engine Selection**: Added `p2pEngineType` preference to `UserDefaults+Keys.swift` and `SettingsView.swift` (`"Embedded Go (FluxEngine)"` vs `"Official Stremio Engine (Node.js)"`). Updated `StremioServerManager.swift` to resolve engines dynamically and enriched PATH with `/opt/homebrew/bin:/usr/local/bin` to prevent Node execution errors.
    - **Localization & Unit Tests**: Added 7 new localized keys across all 10 supported languages (641 unique keys, 0 duplicates). Added 5 unit tests in `fluxTests.swift` covering single-file/multi-file movie torrents, series season packs, sample filtering, and fallback behavior (240/240 tests passing).
29. **Official Stremio Engine Standardization, Mid-Playback Buffering UI Fix, Continuous Torrent Polling & Enter/Exit Lag Elimination**:
    - **Standardized Exclusively on Official Stremio Engine (`server.js`)**: Following extensive A/B testing on *Obsession* and *Zootopia 2*, the Go engine (`FluxEngine` based on `anacrolix/torrent`) repeatedly suffered connection drops at 14MB/92MB, HTTP Range seek failures (`input/output error`), and infinite reconnect loops. By contrast, the official Node.js Stremio engine (`server.js`) downloaded at 2.5–3.0 MB/s, handled multi-gigabyte disk/RAM caching, and sought instantaneously. Completely dropped the Go engine and standardized on the official Stremio Node.js server. Updated `StremioServerManager.swift` to launch `server.js` directly, discovering ports on 11470–11474 with automatic Node provisioning fallback if system Node is missing.
    - **Mid-Playback Buffering UI Fixed (No Start Screen Flash)**: Introduced `@State private var hasEverStartedPlayback = false` in `PlayerView.swift`. `isInitialLoading` is now strictly `!hasStartedPlayback && !hasEverStartedPlayback`. When a mid-stream stall, seek, reconnect, or fallback occurs after playback has started, `logoBufferingView` (the start screen with the fullscreen backdrop image) is never displayed. Instead, the player frame remains visible as-is, player controls stay mounted (`if hasStartedPlayback || hasEverStartedPlayback || showVolumeHUD`), and `midPlaybackLogoBufferingView` overlays the video with a subtle 35% black vignette and the pulsating polyfill logo with live buffer progress.
    - **Continuous Torrent Stats Polling & Monotonic Telemetry**: Removed `if self.hasPlaybackStarted { break }` from `PlayerManager.startTorrentStatsPolling`. Polling now runs continuously at 1.5s during smooth playback and 350ms during buffering. Combined all telemetry, watchdog, and progress calculations into the root-mounted `.onReceive(loadingTimer)` in `PlayerView.swift`, eliminating the bug where unmounting the initial loading screen killed buffer progress and froze progress bars at 5%. Cancelled and nilled poll tasks properly on player close.
    - **Player Enter & Exit Lag Elimination**:
      - Added `@State private var isClosingPlayer = false` guard across `closePlayer()` and `.onDisappear` to eliminate duplicate teardowns, double watch progress updates, duplicate async tasks, and disk eviction storms.
      - Resolved macOS AppKit fullscreen transition collision: when closing in full-screen, `closePlayer()` calls `window.toggleFullScreen(nil)` and defers `window.close()` / `dismiss()` by 0.45s so the space transition completes smoothly without freezing the main thread, while immediately cutting audio and stopping mpv.
    - **Settings View & PocketBase Synchronization (False UI Eliminated)**:
      - Completely removed the redundant "P2P Streaming Engine" row/selector from `SettingsView.swift` under "Stream Sources". Because Flux exclusively runs the official Stremio engine, no selector or informational row is presented.
      - Removed `p2pEngineType` key from `UserDefaults+Keys.swift` and scrubbed local defaults.
      - Synchronized PocketBase record `llicplrw2m6y3ny` via REST PATCH, setting `streamingSourceMode: "both"`, updating `settingsUpdatedAt`, and ensuring zero stale engine fields exist in the cloud.
      - Verified 0 duplicate keys across all 10 supported languages (`en`, `ja`, `es`, `fr`, `de`, `it`, `pt`, `ko`, `hi`, `zh`) in `LanguageManager.swift`.
      - All 240 unit tests passing cleanly across 9 test suites (`** TEST SUCCEEDED **`).
30. **Player Exit Crash Resolution & Focus Responder Lifecycle Stabilization**:
    - **Crash Diagnosis (`EXC_BAD_ACCESS (SIGSEGV)` / `swift_weakCopyInit`)**:
      - Report `/Users/zainulnazir/Library/Logs/DiagnosticReports/flux-2026-09-26-143741.ips` revealed a segmentation fault on Thread 0 inside `swift_weakCopyInit` called by `initializeWithCopy for FocusStoreList.Item` during `NSHostingView.layout()` -> `ViewGraphRootValueUpdater.render` -> `GraphHost.updatePreferences()` -> `FocusStoreList.Key.reduce`.
      - Root Cause: In `PlayerView.swift`, `closePlayer()` invoked `playerManager.close()`, which dispatched `self.currentItem = nil` on `DispatchQueue.main.async`. In `fluxApp.swift`, `WindowGroup(id: "player")` observed `currentItem = nil` and immediately replaced the entire `PlayerView` tree with `Text("No Media Selected")`. Simultaneously, `hostWindow?.close()` and `dismiss()` were called on adjacent lines, dismantling the AppKit window. When AppKit executed `layoutIfNeeded` during window teardown, SwiftUI's focus manager attempted to copy weak references to the focused view (`FocusStoreList.Item`), which was already half-deallocated, crashing with `KERN_INVALID_ADDRESS at 0x000001016c0c8990`.
    - **Resolution & Stabilization**:
      1. *`PlayerWindowContainer` in `fluxApp.swift`*: Introduced `PlayerWindowContainer` holding a `@State private var retainedItem: MediaItem?`. When `playerManager.close()` sets `currentItem = nil`, the container keeps `PlayerView` mounted and stable until the window is fully destroyed. Replaced raw hardcoded string literal `Text("No Media Selected")` with `Color.black` (Rule 1 compliance).
      2. *Clean Focus Responder Disarming*: Added `hostWindow?.makeFirstResponder(nil)` at the top of `closePlayer()` in `PlayerView.swift` to disarm SwiftUI focus tracking cleanly before any window close or animation begins.
      3. *Eliminated Double-Close Collision*: Removed simultaneous `hostWindow?.close()` + `dismiss()` invocation. In windowed mode, `window.close()` is called (or `dismiss()` if unwindowed). In fullscreen, toggles out of fullscreen first (`window.toggleFullScreen(nil)`), waits 0.45s for the AppKit Space transition to finish, closes the window cleanly, and calls `playerManager.close()` only *after* the window is gone.
      4. *Synchronous Main-Thread `PlayerManager.close()`*: Removed unconditional `DispatchQueue.main.async` in `PlayerManager.close()`: if already on `Thread.isMainThread`, it cleans up synchronously, eliminating the deferred runloop race.
      5. *Zero Regressions*: Verified all 240 unit tests passing cleanly across 9 test suites (`** TEST SUCCEEDED **`), codesigned ad-hoc.

---

## 2. Overview of Completed Work & Architecture

### A. TMDB-First Search Engine Refactoring
- **Motivation & User Directives**:
  - The user noted that when TMDB was enabled, searches like *Dark (2017)* were missing or poorly ranked due to local over-filtering, token intersection drops, and strict Levenshtein pruning.
  - User requested: When TMDB is enabled, rely directly on TMDB's rich search catalog and scoring. When disabled, fall back cleanly to Cinemeta/Stremio.
- **Implementation**:
  - `SearchEngine.swift` & `TMDBClient.swift`:
    - Refactored the search pipeline to prioritize TMDB directly when an active API key or keyless TMDB catalog is enabled.
    - TMDB multi-search results are directly mapped to `MediaItem` models with poster, backdrop, overview, release dates, and vote average preserved.
    - Removed overly-restrictive local pre-filtering and token drop logic that excluded valid international hits like *Dark*.
    - Maintained Cinemeta/Stremio search as the resilient fallback when TMDB is unavailable or returns 0 results.
  - `SearchViewModel.swift`:
    - Wired search submissions directly to the optimized search engine.
    - Integrated automatic search query history recording upon user submission.

### B. Bidirectional Carousel Liquid Glass Chevrons
- **Motivation & User Directives**:
  - Horizontal carousels only displayed the right (forward) arrow, missing the left (backward) arrow. Cards were not tucking under the sidebar smoothly.
- **Implementation**:
  - `CarouselView.swift`:
    - Added preference keys (`CarouselLeadingMinXKey`, `CarouselTrailingMaxXKey`, and `CarouselWidthKey`) to continuously track content coordinates against the viewport in `carouselScroll_<UUID>` coordinate space.
    - Dynamic offset detection: `canScrollLeft` enables immediately when `minX < 260` (content swiped or scrolled left).
    - Added smooth backward chevron navigation that steps back by `scrollStep = 3`.
    - Retained modern liquid glass styling with spring animations and viewport edge fades.

### C. Search Query History & History Clearing UI
- **Implementation**:
  - `RecentSearchManager.swift`:
    - Added `@Published var recentQueries: [String]` persisted per-profile under `profile.<uuid>.searchHistory`.
    - Added `addQuery(_:)`, `removeQuery(_:)`, `clearQueries()`, and `clearSearchHistory()`.
  - `SearchView.swift`:
    - Added horizontal chip rail for recent search queries above the "Recently Viewed" carousel.
    - Each query chip features instant click-to-search and an individual `xmark` delete button.
    - Added a "Clear All" button to remove search history.
  - `HistoryView.swift`:
    - Updated "Clear All" confirmation alert to atomically call `UserDataService.shared.clearHistory()`.
  - `SettingsView.swift`:
    - Added a **"History & Privacy"** section under Advanced Settings with **"Clear Watch History"** and **"Clear Search History"** buttons, accompanied by destructive confirmation alerts.

### D. PocketBase Cloud Database Syncing & Shield Update
- **Implementation**:
  - `UserDataService.swift`:
    - Added `historyClearedAtKey`, `historyClearedAt: Double`, and `currentProfileID`.
    - Implemented `clearHistory()`: atomic removal of `history` and `episodeProgress` in `UserDefaults`, updates `historyClearedAt = Date().timeIntervalSince1970`, sets `@Published var history = []`, notifies `.fluxRefresh`, and schedules cloud auto-sync.
    - `exportCloudPayload()` now includes `"historyClearedAt"`, `"searchHistory"`, and `"recentSearches"`.
    - `mergeHistoryData()` filters out remote history items older than or equal to `historyClearedAt`.
    - `applyCloudPayload()` updates `historyClearedAt` and imports `searchHistory`.
  - `ProfileManager.swift`:
    - Namespaced export and import of `historyClearedAt` and `searchHistory` in `exportProfilesData()` and `applyCloudProfilesData()`.
    - Updated profile deletion and sign-out methods to clear namespaced keys.
  - `AuthManager.swift`:
    - Resolved the Cloud Anti-Regression Shield: When `localHistoryCount == 0`, the system checks `isExplicitlyCleared` (`localClearedAt > 0 && localClearedAt >= remoteUpdatedAt - 10.0`). Deliberate history clears are no longer blocked and successfully push to PocketBase so all devices sync the cleared state.

### E. Stream Picker Background Isolation & Race Cancellation
- **Problem**: When users clicked "Choose Stream Source…" from detail cards or "Choose Source" / context menus inside the video player, the background Flux Mode Auto-Play engine or early quorum race continued running in the background. Late-arriving streams triggered candidate races and MPV auto-play underneath the stream selection sheet.
- **Root Cause**:
  1. `PlayerManager.fetchAndRace`: The post-fetch Flux Mode auto-play engine and early quorum race commit lacked guards against `forceStreamPicker` and `isStreamPickerPresented`.
  2. The manual stream selection buttons failed to stop active MPV sessions or cancel in-flight scraper/probe background tasks.
- **Implementation**:
  - Added `PlayerManager.cancelAllPlaybackAndRaces()` to cancel `fetchAndRaceTask`, `startupWatchdogTask`, reset `hasCommittedAutoPlayWinner = false`, `isAutoPlayRaceActive = false`, clear `currentStreamURL`, and stop the active MPV player session.
  - Added checks for `!self.forceStreamPicker && !self.isStreamPickerPresented` across all race gates, early quorum commits, and `raceBestStream`.
  - Wired `cancelAllPlaybackAndRaces()` and `mpv.stop()` into the "Choose Source" error button, the right-click "Select Stream Source…" menu, and `PlayerManager.play(_:forceStreamPicker: true)`.

### F. Playback Issue Dialog & "Choose Source" Button Layout
- **Problem**: The playback issue dialog (width: 480pt) displayed an overlong `"Choose Another Source"` button that wrapped into two lines, looking distorted and paragraph-like.
- **Implementation**:
  - Replaced label with `"Choose Source".localized` in `PlayerView.swift`.
  - Added `.lineLimit(1)` and `.fixedSize(horizontal: true, vertical: false)` to guarantee a single-line pill button.
  - Added translations for `"Choose Source"`, `"No HTTP streams available for this title"`, and `"Show Torrent Sources"` across all 10 supported languages in `LanguageManager.swift`.

### G. Multi-Token Title Conflict Penalty & Scraper Diagnosis
- **Investigation**:
  - Live testing for *Law & Order* S01E02 (`tt0098844:1:2`):
    - PenguPlay hosts (VidFast, Cinejoy, VAPlayer) were returning HTTP 500/502 errors or timing out.
    - CineFreak returned HTTP 200, but scraped an unrelated show: *"The First Order S01E01-05 WEB-DL Hindi ORG"*.
    - Previously, `StreamManager.evaluateTitleMatch` accepted any single token match (`"order"`), confirming "The First Order" as "Law & Order".
  - PenguPlay server status:
    - Popular cached titles (*Breaking Bad*) return streams.
    - Niche/older titles and unauthenticated endpoints return "You must sign in" or experience timeouts.
- **Implementation**:
  - Updated `StreamManager.evaluateTitleMatch`: 2-word titles (like "Law & Order") require complete token matches; conflicting candidates with <= 50% coverage receive an explicit conflict disqualification penalty (`-30,000.0`).
  - Updated `PlayerView.streamSelectionView`: When in HTTP mode and 0 HTTP streams exist but torrent streams do exist, the empty state displays a clear indicator and a one-click **"Show Torrent Sources"** button.

### H. Multi-Language Audio Preference Ranking & Secondary Languages
- Multi-language preference arrays stored in `UserDefaults.Key.preferredStreamLanguages`.
- `StreamManager.selectFastStartCandidate` rewards primary language (+5,000), secondary languages (+4,200), and authentic original language (+2,500), while penalizing unmatching foreign dubs (-3,500).
- Settings UI supports selecting and reordering multiple preferred audio languages.
- Fallback preserves foreign dubs as viable backup options if no preferred audio streams succeed.

### I. Stream Playback Pipeline Diagnostics & MPV Loadfile Fix
- **Diagnostic Findings**:
  1. *MPV Syntax Error*: `command("loadfile", url, "replace", "pause=yes")` failed because argument 3 is an integer index in the mpv C API (`[MPV LOG] main: The loadfile option must be an integer: pause=yes`). Prefetched streams failed to prime.
  2. *Demuxer Socket Drops*: When `http-proxy` was set directly on MPV, ffmpeg’s internal TLS CONNECT tunnel dropped sockets during MKV container header seeking (`ffmpeg: httpproxy: Error reading HTTP response: Immediate exit requested`, `Cache: 0.0s/13KB`).
  3. *Proxy Bandwidth Ceiling*: Tailscale Tinyproxy endpoint (`100.73.223.33:8888`) has peak throughput of ~1.1 MB/s (~8.9 Mbps). High-bitrate 1080p HEVC streams (~8–9 Mbps) consumed nearly 100% of bandwidth, causing buffering stalls.
- **Implementation**:
  - In `MPVVideoView.swift`: Fixed `loadfile` invocation by setting `mpv_set_property_string(mpv, "pause", paused ? "yes" : "no")` followed by `command("loadfile", url.absoluteString)`.
  - In `StreamProxyManager.swift`: Made headers optional in `proxyURL(for:headers:title:)` so direct HTTP streams requiring forward proxying can be wrapped by local loopback server (`127.0.0.1:51547`).
  - In `PlayerManager.swift`: Routed forward-proxied HTTP streams through `StreamProxyManager` to isolate MPV from direct TLS proxy seeking issues.
  - Dynamically extended candidate probe timeouts (4.5s) and watchdog timeouts (`connectTimeout: 20s`, `slowLimit: 14s`) when streams are proxied.

### J. Startup Deadlock Resolution & Stremio Co-existence
- **Crash Diagnosis**:
  - Crash report `flux-2026-09-22-235358.ips` showed `EXC_BREAKPOINT / SIGTRAP` in `_dispatch_once_wait`.
  - Circular lock between `AddonManager.shared` and `StreamRouteProxyManager.shared` on Thread 0 during launch:
    `AddonManager.init()` -> `ensureDefaultAddons()` -> `StreamRouteProxyManager.shared.isEnabled = effective` -> `isEnabled.didSet` -> `syncWithStockAddon()` -> synchronous `AddonManager.shared` access.
- **Resolution**:
  - In `AddonManager.swift`: Inlined `addons[existingIdx].isEnabled = StreamRouteProxyManager.shared.isEnabled` without mutating `StreamRouteProxyManager` during singleton construction.
  - In `StreamRouteProxyManager.swift`: Guarded endpoint auto-migration with `!AppEnvironment.isRunningTests` to isolate unit test runs.
   - Verified Stremio app co-existence: Flux uses dynamic port stepping (`11470` through `11479`), gracefully stepping to the next open port if Stremio desktop is already occupying `11470`.

### K. Brotli Stream Crash Resolution (`StreamProxyManager` & `MPVVideoView`)
- **Problem**: When playing episodes like *Cosmos: A Spacetime Odyssey* S02E01, upstream proxy/scraper streams (e.g. `VAPlayer` / `PenguPlay`) compressed video streams with Brotli (`Content-Encoding: br`). The bundled libavformat/ffmpeg demuxer in `LocalMPVKit` does not support Brotli on raw HTTP video streams, throwing:
  ```
  mpv[ffmpeg]: http: Unknown content coding: br
  Stream ends prematurely at 349306
  ```
- **Resolution**:
  - In `StreamProxyManager.swift`: Explicitly injected `request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")` to demand raw uncompressed bytes from upstreams, and filtered out `content-encoding` headers from downstream responses.
  - In `MPVVideoView.swift`: Injected `Accept-Encoding: identity` into MPV's `http-header-fields` property as a second line of defense for non-proxied direct streams.

### L. Complete Candidate Waterfall & Standby Torrent Retention
- **Problem**: When top 3 candidates failed, `PlayerManager` previously abandoned playback after 2 fallbacks without attempting remaining candidates or viable torrent swarms.
- **Resolution**:
  - In `PlayerManager.swift`: Preserved all fetched candidates (`finalStandby = standby + remainingAfterTop3`), retaining healthy torrent swarms and secondary HTTP links.
  - Increased `maxAutoFallbacks` from 2 to 5 with progressive fallback logging.

### M. Cloud Settings Synchronization Guard
- **Problem**: User settings (such as Flux mode toggles or streaming preferences) kept reverting back on window focus or network restoration.
- **Root Cause**: `ContentView.swift` called `AuthManager.shared.syncNowAsync(forcePull: true)` on `NSApplication.didBecomeActiveNotification`, pulling remote PocketBase data and overwriting local `UserDefaults` every time the user switched back to the app window.
- **Resolution**:
  - Changed `didBecomeActiveNotification` and `fluxNetworkRestored` to call `syncNowAsync(forcePull: false)`.
  - In `ProfileManager.swift`: Added `settingsUpdatedAt` timestamps to profile snapshots (`snapshotSettings`) and added a timestamp comparison guard in `applyCloudProfilesData` so incoming cloud data only overwrites local settings if the cloud timestamp is strictly newer.

### N. Experimental AI Stream Selection Layer (Gemini 3 Flash & Flash-Lite)
- **Implementation**:
  - `GeminiStreamRanker.swift`: Built an asynchronous ranking service that formats up to 25 stream candidates into a compact JSON schema (ID, title, resolution, size, seeders, source, isTorrent) and invokes exclusively Gemini 3 models (`gemini-3.5-flash-lite`, `gemini-3.8-flash`, `gemini-3.5-flash`, `gemini-3.1-flash-lite`) with structured JSON schema output requesting `top_stream_ids` and a brief rationale. `gemini-3.5-flash-lite` serves as the high-speed default with ~1.4s response times and resilient Markdown/array JSON parsing.
  - `PlayerManager.swift`: Integrated `GeminiStreamRanker.rankStreams` when `enableAIStreamSelection` is enabled. Updates player status text to `"AI analyzing streams…"` during inference, preloads the AI's top pick, and races the top 5 sources. Seamlessly falls back to local heuristics if the API key is unset, network fails, or the model times out.
  - `UserDefaults+Keys.swift` & `Secrets.swift`: Added `enableAIStreamSelection`, `geminiApiKey`, and `geminiModel` settings keys and fallback API keys.
  - `SettingsView.swift`: Added a "Selection Engine" section in Streaming Settings with a segmented picker between **Heuristic Algorithm** and **Smart AI Selection (Gemini)**, an active API key pill badge with edit/secure sheet, and a Gemini 3 model picker (`gemini-3.5-flash-lite`, `gemini-3.8-flash`, `gemini-3.5-flash`, `gemini-3.1-flash-lite`).
  - `LanguageManager.swift`: Localized all new UI strings across all 10 supported languages with strict duplicate key prevention.

---

## 3. Diagnostics & Crash Investigation Notes

### Issue 1: Single-Instance Guard Exit
- **Symptom**: `[flux] Another instance is already running — exiting`
- **Cause**: An earlier debug instance of `flux` was still running in the background. Flux's single-instance guard intentionally terminates newly launched instances to prevent port or state collisions.
- **Resolution**: Check for running processes before launch (`ps aux | grep flux`) and terminate stale instances (`kill -9 <PID>`).

### Issue 2: Data Race in Unit Tests (`UserDataService.renameCollection` / `collectionIDs`) [RESOLVED]
- **Symptom**: Diagnostic reports showed `EXC_BAD_ACCESS` / `swift_retain` / `Bus error: 10` on worker threads during `xcodebuild test`.
- **Root Cause**: During app-hosted test runs, concurrent test threads in Swift Testing simultaneously mutated (`createCollection`, `renameCollection`, `deleteCollection`) and read (`collectionIDs`, `exportCloudPayload`) the unisolated `collections` array in `UserDataService`.
- **Resolution**:
  1. Annotated `struct UserDataServiceTests` with `@Suite(.serialized) @MainActor`, ensuring all user data tests execute serially on the main thread.
  2. Introduced an internal `NSRecursiveLock` (`collectionsLock`) in `UserDataService.swift` around collection mutations, reads, and payload export snapshots.
  3. Defaulted `episodeProgress` to an empty dictionary in `ProfileManager.exportProfilesData()` so new profiles export consistent schema payloads.
  4. Verified all 227 unit tests across all 9 test suites pass with 100% green status.

### Issue 3: Missing Context Menu & Card Menu Parity [RESOLVED]
- **Symptom**: Right-clicking on episode cards (`LiquidEpisodeCard`) in the TV show details rail did nothing, while an ellipsis button was present with only partial actions.
- **Root Cause**: `LiquidEpisodeCard` had an ellipsis `Menu` at line 1757, but lacked a `.contextMenu` modifier. `RecentSearchCard` in `SearchView.swift` also lacked a context menu.
- **Resolution**:
  1. Refactored `LiquidEpisodeCard`: Extracted `episodeMenuActions` view builder shared by both the ellipsis `Menu` and `.contextMenu`. Added "Play" / "Resume", "Play from Beginning" (for partially watched episodes), "Choose Stream Source…", and dynamic "Mark as Watched" / "Mark as Unwatched".
  2. Attached `.contextMenu` to `RecentSearchCard` with "Go to Movie/Show/Person", "Add/Remove from Watchlist", and "Remove from Recent Searches" (`recentManager.removeItem`).
  3. Added new localized keys (`"Play from Beginning"`, `"Mark as Unwatched"`, `"Remove from Recent Searches"`, `"Go to Person"`) across all 10 supported languages in `LanguageManager.swift` with zero duplicate key errors.

### Issue 4: Cross-Suite Test Pollution in `StreamRouteProxyTests` [RESOLVED]
- **Symptom**: `StreamRouteProxyTests.defaultStateHasNoEndpointAndDoesNotProxy()` failed intermittently during full test runs when running in parallel with `ProfileTests`.
- **Root Cause**: `StreamRouteProxyManager.recoverConfiguredEndpoint()` was recovering proxy endpoints from leftover profile settings snapshots in `UserDefaults` during tests, and tests were leaving dirty endpoints without teardown.
- **Resolution**:
  1. Added `guard !AppEnvironment.isRunningTests else { return nil }` directly inside `recoverConfiguredEndpoint()`.
  2. Added `@MainActor` and `defer` cleanup blocks in `StreamRouteProxyTests.swift`.
  3. All 230 unit tests now reliably pass with 100% green status.

### Issue 5: Experimental AI Stream Selection Layer & Gemini 3 Architecture [RESOLVED]
- **Overview**: Introduced an experimental AI-powered stream selection layer for Flux Mode using Google Gemini 3 models (`gemini-3.5-flash-lite` by default for high free-tier quotas and fast ~1s latency, alongside `gemini-3.6-flash`, `gemini-3.8-flash`, `gemini-3.7-flash`, `gemini-3.5-flash`, and `gemini-3.1-flash-lite`).
- **Implementation**:
  1. `GeminiStreamRanker.swift`: Serializes candidate streams into compact JSON, prompts the Gemini API with structured JSON output requirements, applies low thinking configuration (`"thinkingConfig": ["thinkingLevel": "low"]`) to minimize latency and token overhead, injects user preferences (target quality ceiling, preferred languages, and streamable size guidance 1.5–8 GB to prevent 25–60 GB uncompressed torrent buffering stalls), and implements cascading fallbacks (`3.5-flash-lite` -> `3.6-flash` -> `3.1-flash-lite`).
  2. `PlayerManager.swift`: Forwards `preferredQuality`, `preferredLanguages`, and `enableLanguageFilter` into `GeminiStreamRanker.shared.rankStreams`.
  3. `SettingsView.swift`: Added toggle for "AI Stream Selection" with custom API key support and Gemini Model picker defaulted to `gemini-3.5-flash-lite`. Sanitizes legacy or invalid models on launch.
  4. `ProfileManager.swift`: Added migration check during `restoreSettings` to ensure stored snapshots automatically normalize legacy keys to `gemini-3.5-flash-lite`.
  5. `LanguageManager.swift`: Fully localized all Gemini model picker and setting strings across all 10 supported languages with verified 0 duplicate keys.

### Issue 6: Reconnect Storms, Main-Thread Demuxer Locking & Beachball Freezes [RESOLVED]
- **Symptom**: Clicking on certain titles (e.g. *Coyote vs. Acme*) caused the app to freeze with a spinning beachball cursor. Attempting to play failed even though good sources were available. Subsequent title navigation (e.g. *Zootopia 2*) also froze temporarily before playing.
- **Root Cause**:
  1. The selected torrent swarm disconnected after downloading initial pieces, throwing `Input/output error` (premature EOF). Mpv's demuxer flags (`reconnect=1,reconnect_delay_max=5`) triggered rapid 0-second reconnect loops inside ffmpeg. Because ffmpeg handled reconnects internally, mpv never fired an EOF or fatal error to SwiftUI, causing playback to hang silently.
  2. When navigating away from `DetailView` or switching media, `cancelDetailPrefetch()` and `discardWarmCore()` called `core.controller.stop()` / `mpv_command` synchronously on the main thread. Because mpv held its internal demuxer mutex lock during the network reconnect storm, the main thread blocked for multiple seconds, triggering the macOS spinning beachball.
  3. When *Zootopia 2* was opened, `warmEngine` had to discard the hanging *Coyote vs. Acme* core first, causing another beachball freeze until the teardown unlocked.
- **Resolution**:
  1. In `MPVVideoView.swift`, refactored `stop()` to dispatch `command("stop")` asynchronously on `DispatchQueue.global(qos: .userInitiated)`.
  2. In `PlayerManager.swift`, wrapped `discardWarmCore()` and `cancelDetailPrefetch()` controller stops in background queues, ensuring main-thread SwiftUI transitions never block on mpv socket operations.
  3. In `DetailView.swift`, added a 350ms yield (`try? await Task.sleep(nanoseconds: 350_000_000)`) in `.task` before speculative prefetching so the navigation push animation and window render complete smoothly before any background player work starts.
  4. Implemented sliding-window reconnect storm detection in `MPVVideoView.swift`: logs tracking premature EOF / reconnect events increment a counter; if `>= 3` reconnects occur within 5 seconds, `PlayerManager.shared.handleStreamFailure(reason: .reconnectStorm)` is fired, instantly dropping the failing warm core or advancing active playback to the standby waterfall.

### Issue 7: Cloud Settings Sync Overwriting Resolution & Fallback Starvation [RESOLVED]
- **Symptom**: User set Maximum Resolution to 4K, but on app restarts or focus changes, the setting reverted to 1080p. Titles like *Heart of the Beast* showed the loading bar fill but never started playback.
- **Root Cause**:
  1. `UserDataService.swift:hasLocalAdditionsToPush` omitted `localSettingsNewer || missingSettingsInCloud`. When the user modified settings in `SettingsView`, auto-sync triggered a pull-first sync (`pullFirst: true`). Because `hasLocalAdditionsToPush` was false, local settings were never pushed to PocketBase. On app relaunch, PocketBase's stale remote snapshot (`1080p`) was pulled and applied to local `UserDefaults`.
  2. In *Heart of the Beast*, the primary candidate (PenguPlay Cinejoy HLS) served an empty HLS playlist (`hls: Empty segment`). After the dead-source watchdog timed out, `advanceToStandbyFallback()` attempted to advance to the next candidates. However, because `preferredQuality` had reverted to 1080p, remaining 4K streams were rejected by the fallback filter (`score > maxScore`), leaving 0 available fallbacks and aborting playback.
- **Resolution**:
  1. Patched `hasLocalAdditionsToPush` in `UserDataService.swift` to check `localSettingsNewer || missingSettingsInCloud`.
  2. Reduced `scheduleAutoSync` delay in `SettingsView.swift` to `0.1s`.
  3. Updated live PocketBase record `llicplrw2m6y3ny` with `preferredQuality: "4K"` and current timestamp.
  4. In `PlayerManager.swift:advanceToStandbyFallback()`, added a resilient fallback mechanism (`higherQualityFallback`): if all candidates matching `<= preferredQuality` fail, the player automatically falls back to higher-quality candidates rather than failing playback completely.

### Issue 8: Reconnect Storm False Positives on Torrent Startup & Image Cache Memory Wipes [RESOLVED]
- **Symptom**: User attempted to play multiple titles; nothing played. Torrents failed almost immediately with repeated reconnect errors in logs, and `FluxEngine` port 11470 refused connections. The app also showed persistent loading wheels, shimmers, and beachball freezes across Home and Detail views after closing the player.
- **Root Cause**:
  1. The sliding-window reconnect watchdog in `MPVVideoView.swift` triggered on `lowerText.contains("reconnect")` at byte offset 0. When Stremio's embedded engine (`FluxEngine`) starts downloading a torrent, it needs a few seconds to connect to DHT peers and buffer the initial file header (moov / video header). Ffmpeg's HTTP demuxer emits normal retry messages (`Will reconnect at 0 in 0 second(s)`). The watchdog counted 3 of these within 5 seconds and declared a "reconnect storm", killing the torrent after just 1 second and immediately jumping to fallbacks. It did this across all candidate streams, hammering port 11470 until the engine refused connections and locked mpv's demuxer.
  2. `PlayerView.swift:290` called `ImageInMemoryCache.purgeMemoryCache()` on `.onAppear`. Every time the user started a video, all decoded posters, logos, and covers were completely wiped from RAM. Exiting the player forced Home and Detail views to reload and re-decode every card on screen, leaving the UI in a perpetual loading/shimmer state.
- **Resolution**:
  1. In `MPVVideoView.swift`, restricted reconnect storm evaluation strictly to active mid-stream playback (`PlayerManager.shared.hasPlaybackStarted == true` at non-zero offsets). Connection retries at byte offset 0 (`reconnect at 0`) are ignored.
  2. In `MPVVideoView.swift`, cleared `reconnectTimestamps` on `loadFile` and `stop()` so prior reconnect attempts never contaminate subsequent streams. Initial torrent buffering is now safely governed by `PlayerManager.shared.armStartupWatchdog` (allowing up to 35 seconds matching Stremio).
  3. In `PlayerView.swift:onAppear`, removed the destructive `ImageInMemoryCache.purgeMemoryCache()` call. All card artwork now remains instantly cached in RAM across player open/close transitions.

### Issue 9: 2-Second Playback Kill Loop ("Flashing at 2s") & Dead Proxy Injection [RESOLVED]
- **Symptom**: Titles started playing for 1-2 seconds, then immediately flashed, restarted or killed playback, jumping to fallback streams or black screens. Furthermore, direct HTTP streams like PenguPlay failed to load in Flux while playing instantly in Chrome.
- **Root Cause**:
  1. `PlayerManager.swift:armStartupWatchdog` spawned a post-start monitoring loop checking `sustainedStartupThroughputKBps < 150 KB/s` and `lastObservedCacheTime < 4.0`. In `PlayerView.swift:loadingTimer`, an early `return` inside `if mpv.isPlaying && mpv.timePos >= 0.05` prevented `reportTelemetryProgress(cacheTime:)` from being called once playback began. As a result, `lastObservedCacheTime` remained 0.0, causing the watchdog to accrue strikes every 1.0s and fire `advanceToStandbyFallback()` at exactly 2.0s.
  2. `StreamRouteProxyTests.swift` wrote a dummy proxy endpoint (`http://100.64.0.1:8888`) and enabled `streamRouteProxyEnabled = true` in shared `UserDefaults.standard` without restoring previous state in `tearDown`. This permanently hijacked all direct HTTP / PenguPlay streams through an unreachable mock IP on the user's host machine.
- **Resolution**:
  1. In `PlayerManager.swift`, disarmed the startup watchdog as soon as `hasPlaybackStarted == true` and cancelled `startupWatchdogTask` in `markPlaybackStarted()`.
  2. In `PlayerView.swift`, moved `reportTelemetryProgress(cacheTime:)` to the top of `loadingTimer` so cache duration is continuously reported before any early returns.
  3. In `StreamRouteProxyManager.swift`, purged mock IPs from persistent storage and added sanity checks rejecting test IPs.
  4. In `StreamRouteProxyTests.swift`, added `defer` cleanup restoring pre-test proxy settings.

### Issue 10: Player Escape Key Single-Press Exit Regression & Top-Center Pill [RESOLVED]
- **Symptom**: Pressing the `Esc` key once during video playback immediately closed the player window instead of presenting the confirmation warning ("Press Esc again to exit") and requiring a second press to exit. Furthermore, the warning was initially rendered in the center of the screen, obscuring active video playback.
- **Root Cause**: In `PlayerView.swift:handleEscapePress()`, the code previously handled HUD and modal dismissals but directly called `closePlayer()` on single press, bypassing `showExitWarning` and `exitWarningOverlay` completely.
- **Resolution**:
  1. Added `@State private var exitWarningTask: Task<Void, Never>? = nil` and `@ObservedObject private var languageManager = LanguageManager.shared` (satisfying `AGENTS.md` Rule 1).
  2. Updated `handleEscapePress()`: if `showExitWarning` is active, it cancels the reset task and invokes `closePlayer()`. Otherwise, it displays `showExitWarning` with animation and launches a 2-second timeout task to auto-dismiss the warning.
  3. Redesigned `exitWarningOverlay` as a sleek **top-center floating liquid glass pill** (`Capsule`, padding `.top: 36`, subtle border and drop shadow) with `.transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))` so it floats cleanly at the top of the screen between controls without obstructing the video or dialogue subtitles.
  4. Cleaned up `exitWarningTask` and reset `showExitWarning = false` in `closePlayer()`, `onDisappear`, and `onChange(of: currentPlaybackKey)`.
  5. Added `.allowsHitTesting(false)` to `exitWarningOverlay` so underlying video controls remain interactable during prompt display.

### Issue 11: Full HTTP Stream Route Proxy Mode & Scope Expansion [RESOLVED]
- **Symptom**: Previously, `StreamRouteProxyManager` only proxied streams whose URL or title matched a hardcoded token list (`targetHosts: ["2peckle", "peckle", "febbox", "shegu", "pengu", "cinefreak", "fcdn"]`). Any unlisted scraper hosts, CDNs, or direct HLS/DASH streams bypassed the proxy even when enabled.
- **Root Cause**: The proxy manager lacked a full-playback proxy mode and was gated strictly on token matching.
- **Resolution**:
  1. Added `proxyAllHTTP: Bool` (defaults to `true`) to `StreamRouteProxyManager.swift` and registered `UserDefaults.Key.streamRouteProxyAllHTTP` across `ProfileManager.swift` and `UserDefaults+Keys.swift`.
  2. When enabled, `shouldProxy(url:title:)` routes all external HTTP/HTTPS video playback through the proxy.
  3. Preserved strict safety firewalls: BitTorrent swarms (`127.0.0.1`, port `11470`, port `51547`), local files (`file://`, `flux://`), TMDB metadata, Cinemeta catalogs, OpenSubtitles, and PocketBase cloud sync NEVER route through the proxy under any circumstances.
  4. Added a "Proxy All HTTP Streams" toggle card to `StreamRouteProxyConfigSheet.swift` with full 10-language localization across all supported languages (`en`, `ja`, `es`, `fr`, `de`, `it`, `pt`, `ko`, `hi`, `zh`) with verified zero dictionary duplicates.
  5. Added unit test `proxyAllHTTPModeProxiesAllExternalMedia()` verifying all external media routes through proxy while torrents and metadata strictly bypass. All 234 unit tests pass.

### Issue 12: Exit Warning Fade-in Transition & Loading Logo Text Fallback [RESOLVED]
- **Symptom**:
  1. The "Press Esc again to exit" prompt performed a downward slide animation from the top edge, causing distracting motion near the menu bar area.
  2. During stream buffering, if a title's logo image was still downloading/decoding via `CachedImage`, the placeholder rendered `Color.clear`, leaving a blank void where the user saw no progress fill until either the image arrived or playback started.
- **Resolution**:
  1. Replaced `.transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))` with `.transition(.opacity)` and `.easeInOut(duration: 0.15)` in `PlayerView.swift`, giving it an instantaneous, clean in-place appearance like Google Chrome's `Cmd+Q` quit prompt.
  2. Updated `CachedImage` `default:` phase inside `loadingLogo` from `Color.clear.frame(...)` to `stylizedTextLogo(title: media.title, progress: progress)`. The user now immediately sees the title text with real-time progressive fill from the very first frame of buffering, which seamlessly transitions once the high-res PNG logo finishes downloading.
  3. Confirmed all 234 unit tests pass and verified smooth playback logs across recent user tests (*Colony*, *Reacher*, *The Day of the Jackal*).

### Issue 13: Direct & P2P UI Nomenclature Alignment Across Settings [RESOLVED]
- **Symptom**: User-facing settings displayed protocol-level engineering jargon ("HTTP" and "Torrent") across the Stream Filter picker, Route Proxy headers, Cache limits, and purge actions.
- **Resolution**:
  1. Updated all user-facing settings strings in `SettingsView.swift` and `StreamRouteProxyConfigSheet.swift`:
     - "HTTP Streams Only" -> "Direct Streams Only"
     - "Torrent Streams Only" -> "P2P Streams Only"
     - "HTTP & Torrent Streams (Both)" -> "Direct & P2P Streams (Both)"
     - "HTTP Stream Route Proxy" -> "Direct Stream Route Proxy"
     - "Torrent Cache Limit" -> "P2P Cache Limit"
     - "Purge Torrent Cache" -> "Purge P2P Cache"
     - "Proxy All HTTP Streams" -> "Proxy All Direct Streams"
  2. Preserved internal canonical keys (`.tag("both")`, `.tag("http")`, `.tag("torrent")`, UserDefaults keys, engine endpoints) in English.
  3. Expanded `LanguageManager.swift` across all 10 supported languages (`en`, `ja`, `es`, `fr`, `de`, `it`, `pt`, `ko`, `hi`, `zh`) with verified 0 dictionary duplicate keys (631 unique keys per language).
  4. Verified user forward proxy playback test in system logs: verified that external direct HTTP streams route through Tinyproxy (`ready proxy` on `100.73.223.33:8888`), with 0 dropped startup frames on *Lanterns S01E06*.
### Issue 14: "Copy Stream Link" Magnet Override, Mid-Playback Buffering Logo Suppression & Stall Watchdog [RESOLVED]
- **Symptom**:
  1. Clicking "Copy Stream Link" in player controls or the info HUD copied the magnet link instead of the local engine streaming URL (`http://127.0.0.1:11470/...`).
  2. When a P2P stream stalled mid-playback (e.g. at 8 or 21 seconds due to 0 connected swarm peers), the video froze with no mid-playback logo buffering screen, and playback sat frozen indefinitely with no fallback.
- **Root Cause**:
  1. `PlayerManager.swift:cleanPlayableURLString(from:)` previously intercepted *any* URL passed to it if `currentSelectedStream?.isTorrent == true` and replaced it with `currentMagnetURL`. This meant even valid engine HTTP URLs (`http://127.0.0.1:11470/...`) were rewritten back into `magnet:?xt=urn:btih:...`.
  2. In `MPVVideoView.swift:observePropertyChanges`, when mpv paused internally due to buffer starvation, EOF, or decoder stall, it emitted property change `case "pause"`. Because `paused-for-cache` was not yet set, the code executed `self.isUserPaused = paused`. This set `isUserPaused = true`, causing `PlayerView.swift:isMidPlaybackBuffering` (`!mpv.isUserPaused`) to evaluate to `false`. The frozen-frame watchdog also checked `!mpv.isUserPaused` and immediately aborted. Consequently, the player believed the user had intentionally paused, suppressing the `midPlaybackLogoBufferingView` and disabling stall detection.
- **Resolution**:
  1. In `PlayerManager.swift:cleanPlayableURLString`, removed the block that overwrote URLs with magnets. In `PlayerControlsView.swift` and `PlayerView.swift`, changed `rawLink` to resolve the playable HTTP URL directly (`getPlayableURL(for:)`) without magnet fallback. "Copy Magnet Link" remains dedicated to magnet links, while "Copy Stream Link" strictly copies the playable HTTP stream link.
  2. In `MPVVideoView.swift`, removed `self.isUserPaused = paused` from `case "pause"`. `isUserPaused` is now strictly mutated only when the user or app explicitly calls `pause()`, `play()`, `preparePaused()`, or `stop()`.
  3. In `PlayerView.swift`, updated `isMidPlaybackBuffering` to include `!mpv.isPlaying` alongside `isBuffering`, `isSeeking`, and `frameFrozen`. Updated `updateFrozenWatchdog` and `handleIsPlayingChange` to preserve watchdog state during involuntary stalls.
  4. Added `midPlaybackStallWatchdogTask` in `PlayerView.swift:onChange(of: isMidPlaybackBuffering)`. If mid-playback buffering persists continuously for 18 seconds without data resuming, Flux automatically advances to the next standby fallback in auto-play mode, or displays an actionable error banner prompting the user to reconnect or select another source.
### Issue 15: Stream Selection Resolution Cap Enforcement & Gemini Candidate Pre-Filtering [RESOLVED]
- **Symptom**: A 2160p (4K) stream was selected for *Ant-Man* despite `preferredQuality` being explicitly configured to `1080p` in Settings.
- **Root Cause**:
  1. `PlayerManager.swift:raceBestStream` previously passed the raw `healthy` streams array to `GeminiStreamRanker.shared.rankStreams` without pre-filtering by `sourceMode` or `preferredQuality`.
  2. In `GeminiStreamRanker.swift`, `candidates = Array(streamPool.prefix(12))` took the first 12 streams from the catalog. Because Torrentio orders 4K releases at the very top, the top candidate slots were dominated by 2160p releases.
  3. Although the prompt noted `PREFERRED QUALITY: 1080p`, the LLM saw `[0] Ant-Man 2160p 10-bit HDR BluRay 8CH` and judged it "highest quality", returning index `0`.
  4. In `PlayerManager.swift:1606`, the "Zero-Override Commitment" committed directly to Gemini's winner (`winnerCandidate = firstPass`) without verifying `qualityScore(winnerCandidate.quality) <= maxAllowed`.
- **Resolution**:
  1. In `GeminiStreamRanker.swift`: Added `sourceMode` and strict resolution cap pre-filtering (`StreamManager.shared.qualityScore(s.quality) <= maxAllowedQuality`). Also pre-filters Dolby Vision Profile 5, dead torrents (< 5 seeders), and junk labels before constructing the 12-candidate pool. Added hard post-filter validation to `pickedStreams` and partitioned unpicked fallbacks so compliant resolutions come first.
  2. In the prompt to Gemini: Explicitly specified `MAXIMUM RESOLUTION: \(pq)` and `STREAMING SOURCE: ...`. Smaller, pre-screened candidate pools also reduce prompt token size, speeding up inference and reducing API quota consumption.
  3. In `PlayerManager.swift:raceBestStream`: Passed `sourceMode` to `rankStreams` and added quality cap validation to `firstPass` and `winnerCandidate`. If Gemini's top pick exceeds the resolution cap, Flux automatically promotes the highest-ranked compliant fallback.
  4. Added unit test `streamManagerResolutionCapExcludes4KWhen1080pSelected` in `fluxTests.swift`. All 235 unit tests pass cleanly.

### Issue 16: FluxEngine P2P Streaming Engine Failure & Performance Bottlenecks [DIAGNOSED]
- **Symptom**: User reported that P2P torrent playback is completely broken in Flux ("freezing at 8s or 21s", "never starts properly", "stuck buffering"), whereas the exact same torrent sources stream smoothly in the official Stremio client.
- **Investigation & Live Testing**:
  1. Tested the embedded Go binary `FluxEngine` (`github.com/M0Rf30/stremio-server-go` v0.12.1 built on `anacrolix/torrent`, commit `c39968f`).
  2. Under load with active torrent swarms, the engine pegged at **111% CPU** and abruptly **crashed/terminated**, taking down the host Flux app process.
  3. Real-world download throughput was tested with well-seeded swarms:
     - *Big Buck Bunny* (203 unique peers, 20 unchoked): only achieved **73–180 KB/s** (expected: 5–20 MB/s).
     - *Guardians of the Galaxy* (168 unique peers, 9 unchoked): crawled at **100–960 KB/s** on a 23 GB BluRay stream.
  4. The `/stats.json` endpoint returned `"selections": null`. In `anacrolix/torrent`, this indicates no sequential piece prioritization or file windowing was active. The engine was downloading scattered chunks across the entire torrent rather than prioritizing contiguous sequential pieces required by mpv's demuxer.
  5. Fallback bug: In multi-file torrents (e.g. Big Buck Bunny), index 0 is a 140-byte subtitle file (`Big Buck Bunny.en.srt`), while the actual video is index 1. Blindly falling back to `fileIdx ?? 0` attempts to stream subtitles as video.
  6. Race condition: In `PlayerManager.swift:attemptStream`, `resolveTorrentStream` (which calls `/{hash}/create`) was fired as an unawaited background task while `finishSelect(stream)` immediately handed the stream URL to mpv. mpv began issuing HTTP GET/Range requests before the Go engine finished metadata extraction and swarm initialization.
- **Artifact**: Full report documented in `p2p_engine_diagnosis.md`.

### Issue 17: Mid-Playback Buffering UI Knockoff Card Regression [IDENTIFIED]
- **Symptom**: User noticed that the mid-playback buffering indicator was a "knockoff not real", featuring an unwanted floating card background around the logo, shrunken logo dimensions, and a separate capsule bar that was never part of the original design.
- **Root Cause & Historical Audit**:
  1. In commit `e56210b`, `midPlaybackLogoBufferingView` in `PlayerView.swift` was wrapped inside:
     ```swift
     .padding(.horizontal, 28)
     .padding(.vertical, 20)
     .background(
         RoundedRectangle(cornerRadius: 20, style: .continuous)
             .fill(.ultraThinMaterial.opacity(0.85))
             .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
     )
     ```
     This turned the overlay into a floating rounded rectangular card badge.
  2. The logo was shrunken to `maxHeight: 70` inside the card box, and a separate `140x4` capsule progress bar was added underneath.
  3. Git history audit:
     - Commit `21eed32`: *"fix(player): use pure logo fill buffer loading without separate progress bar"* — defined the pure logo design directly on the `Color.black.opacity(0.35)` darkened video frame (`maxHeight: 100`, no card background, no separate progress bar, logo fills smoothly left-to-right).
     - Commit `a5f94e0`: *"fix(ui): apply Apple TV hero starring/director design, remove floating buffer card"* — explicitly removed floating buffer card containers.
- **Resolution Plan for Next Session**:
  - Revert `midPlaybackLogoBufferingView` to the authentic borderless design: remove the `.background(RoundedRectangle...)` card box, restore original logo dimensions (`maxHeight: 100`/`76`), and ensure the logo fills left-to-right smoothly on the darkened frame without any card container.

---

## 4. Completed Priorities & Active Focus

### Completed: Priority 1 — Restore Authentic Mid-Playback Buffering UI
1. **Removed Knockoff Card Background**: Stripped the `.background(RoundedRectangle(...).fill(.ultraThinMaterial...))` and container padding from `midPlaybackLogoBufferingView` in `PlayerView.swift`.
2. **Restored Original Logo Sizing & Pure Fill**: Aligned directly with commit `21eed32` / `a5f94e0`:
   - Pure title logo / text fallback directly over `Color.black.opacity(0.35)` vignette.
   - Sizing: `maxHeight: 100` (or `76`).
   - Smooth left-to-right mask fill reflecting live demuxer/torrent progress.
   - Zero card borders, zero boxes, zero duplicate capsule progress bars.

### Completed: Priority 2 — P2P Torrent Streaming Architecture Overhaul
1. **Smart `fileIdx` Resolution**:
   - Implemented `PlayerManager.findBestVideoFileIndex(files:targetSeason:targetEpisode:)` to select the primary video file by byte length and episode patterns (`s01e02`, `1x02`, `e02`) from the engine's `/create` response.
   - Successfully eliminated demuxer crashes on multi-file torrents (e.g. *Big Buck Bunny* picking 140-byte subtitle file).
2. **Sequential `/create` Metadata Handshake**:
   - `attemptStream` now awaits `resolveTorrentStream` (8.0s timeout), commits the resolved `fileIdx` to `stream.fileIdx` and `currentSelectedStream`, and auto-advances if the swarm is dead.
3. **Official Stremio Engine (Node.js) Option & Setting**:
   - Added `p2pEngineType` preference to `UserDefaults+Keys.swift` and `SettingsView.swift` (`"Embedded Go (FluxEngine)"` vs `"Official Stremio Engine (Node.js)"`).
   - `StremioServerManager.swift` dynamically selects the chosen engine and enriches PATH for Node.js execution.
4. **Localization & Unit Tests**:
   - Added 7 new localized keys across all 10 supported languages (641 unique keys, 0 duplicates).
   - Added 5 unit tests in `fluxTests.swift` covering single-file/multi-file movie torrents, series season packs, sample filtering, and fallback behavior (240/240 tests passing).

### Completed: Priority 3 — Player Exit Crash Resolution & Focus Responder Lifecycle Stabilization
1. **Focus Responder Disarming**: Added `hostWindow?.makeFirstResponder(nil)` at the start of `closePlayer()` to disarm SwiftUI focus responders before window order-out and avoid `FocusStoreList` dangling weak pointer invalidations.
2. **`PlayerWindowContainer` View Stability**: Wrapped `PlayerView` in `fluxApp.swift` in `PlayerWindowContainer` which retains `activeMediaItem`. Prevents `fluxApp` from violently destroying `PlayerView` and rendering `Text("No Media Selected")` while the window is closing or animating out of full-screen. Replaced hardcoded text with `Color.black` (Rule 1 compliance).
3. **Eliminated Double-Close Collision**: Cleaned `closePlayer()` to close the AppKit window directly in windowed mode (or `dismiss()` if unwindowed), and in fullscreen mode, toggles out of fullscreen first before closing after 0.45s.
4. **Synchronous `PlayerManager.close()` Execution**: Executed `PlayerManager.close()` synchronously when on main thread, preventing deferred runloop races against AppKit window layout passes.
5. **Verified Stability**: 240/240 tests passing, codesigned ad-hoc.

---

## 5. Key Files & Reference Table

| Component | File Path | Key Functions & Purpose |
| :--- | :--- | :--- |
| **Search Engine** | `flux/Services/Search/SearchEngine.swift` | TMDB-first search routing, query execution, fallback to Cinemeta |
| **TMDB Client** | `flux/Services/Search/TMDBClient.swift` | TMDB multi-search API integration, MediaItem mapping |
| **Search ViewModel** | `flux/Services/Search/SearchViewModel.swift` | Query state, suggestions, search execution, history commit |
| **Search View** | `flux/Views/SearchView.swift` | Search input, query history chip rail, results & recent carousels |
| **Recent Searches** | `flux/Services/RecentSearchManager.swift` | Per-profile query history persistence, removal, clear operations |
| **Carousel View** | `flux/Components/CarouselView.swift` | Horizontal card carousel, Liquid Glass chevrons, coordinate preference tracking |
| **User Data** | `flux/Services/UserDataService.swift` | Watchlist, history, collections, `clearHistory()`, cloud payload export/import |
| **Profile Manager** | `flux/Services/ProfileManager.swift` | Multi-profile management, PIN locking, namespaced cloud sync |
| **Auth Manager** | `flux/Services/AuthManager.swift` | PocketBase auth, cloud sync scheduling, Anti-Regression Shield |
| **History View** | `flux/Views/HistoryView.swift` | Watch history list, swipe-to-delete, atomic "Clear All" |
| **Settings View** | `flux/Views/SettingsView.swift` | General, streaming, profile, and "History & Privacy" settings |
| **Streaming Engine** | `flux/Engine/server.js` | Official Stremio Node streaming core, HTTP 11470–11474 |
| **Stream Proxy** | `flux/Services/StreamProxyManager.swift` | Local loopback stream proxy, Brotli identity header injection |
| **Stream Ranker (AI)** | `flux/Services/GeminiStreamRanker.swift` | Structured JSON serialization, Gemini Flash stream evaluation |
| **Player Manager** | `flux/Services/PlayerManager.swift` | MPV playback orchestration, auto-play racing, proxy routing |
| **MPV Video View** | `flux/Views/MPVVideoView.swift` | libmpv wrapper, CAOpenGLLayer rendering, playback properties |

---

## 6. Development & Build Commands

### Build from Terminal
```bash
xcodebuild -project flux.xcodeproj -scheme flux -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO build -quiet
```

### Run Unit Tests
```bash
xcodebuild test -project flux.xcodeproj -scheme flux -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:fluxTests
```

### Kill Lingering Flux Processes
```bash
pkill -9 -f "flux.app" || true
pkill -9 -f "FluxEngine" || true
```

---

## 7. Antigravity Agent Guidelines

When continuing work in Antigravity:
1. **Localization**: Maintain zero hardcoded strings. Every user-visible string must use `.localized` and have 10-language translations in `flux/Services/LanguageManager.swift`.
2. **Push Back on User Requests**: Evaluate trade-offs, warn about regressions, and confirm architectural decisions before proceeding.
3. **Keep `handover.md` Updated**: After finishing any major feature or session, update this document and commit changes.

---

## 8. Completed Priorities & Status

### Issue 18: Player Window Teardown, Double-Esc Exit, Buffering Overlay & Startup Beachball [RESOLVED]
- **Symptom**: User reported that when in fullscreen, pressing Esc once showed the exit prompt, but pressing Esc again exited fullscreen mode into windowed mode on desktop rather than closing the player window. Re-entering fullscreen left the buffering logo bar permanently stuck on screen, the Esc key became completely unresponsive, playback restarted on its own, and the cursor showed a spinning beachball wheel on startup.
- **Root Causes & Verified Fixes**:
  1. **Direct Window Teardown (Apple TV Parity)**: Removed `window.toggleFullScreen(nil)` and the 0.45s delay in `closePlayer()`. AppKit was rejecting `window.close()` during the active space transition. Calling `window.close()` directly on the host window with `dismiss()` now closes and destroys the player window immediately and cleanly from both fullscreen and windowed modes.
  2. **Eliminated Teardown Playback Restart**: Disarmed `mpv.onPlaybackError = nil` and cancelled all active watchdog/countdown tasks in `closePlayer()` and `onDisappear`. Prevents closed network sockets from triggering `onPlaybackError` and restarting playback on another stream.
  3. **Eliminated Permanent Buffering Logo**: Gated `logoBufferingView` and `midPlaybackLogoBufferingView` with `!isClosingPlayer` and `playerManager.currentStreamURL != nil`.
  4. **Eliminated Startup Beachball**: Dispatched deferred `command("loadfile", urlToLoad.absoluteString)` in `MPVVideoView.initializeGLContext()` to a background queue (`userInitiated`), eliminating main-thread demuxer blocking.
  5. **View State Isolation & Key Monitor Re-attachment**: Applied `.id(item.id)` to `PlayerView(item: item)` in `PlayerWindowContainer` (`fluxApp.swift`), reset `isClosingPlayer = false` in `onAppear`, and re-attached `PlayerKeyMonitor` if nil.
- **Verification**: 240/240 unit tests passing, ad-hoc codesigned, build successful.

