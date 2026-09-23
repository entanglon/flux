# Flux Project Handover & Session Summary
**Updated**: September 23, 2026 (11:35 AM IST)  
**Latest Git Commit**: `f759d2e` (with clean working tree)  
**Target Platform**: macOS 14.0+ (Universal / Apple Silicon arm64)  
**Xcode Target**: `flux` (Scheme: `flux`, Test Plan: `fluxTests`)  

---

## 1. Executive Summary for Antigravity Sessions

This project is **Flux**, an open-source, modern native macOS media and streaming application built with SwiftUI, an embedded Go streaming engine (`FluxEngine` / Stremio core), native `libmpv` video playback via `LocalMPVKit`, PocketBase backend sync, and TMDB / Stremio addon catalog aggregation.

The app has just undergone major enhancements:
1. **Direct TMDB-First Search Engine**: Direct integration with TMDB search without restrictive pre-filtering or token penalties, ensuring international and catalog titles (e.g., *Dark 2017*) surface accurately, with Cinemeta/Stremio fallback.
2. **Bidirectional Liquid Glass Carousel Navigation**: Viewport coordinate tracking dynamically displays both left and right chevrons and enables smooth multi-card scrolling under the sidebar.
3. **Search Query History**: Namespaced per-profile recent query chips with individual delete and "Clear All" actions.
4. **Watch & Search History Clearing with PocketBase Cloud Sync**: Full atomic purge capabilities in Settings and History with Anti-Regression Shield protections so intentional wipes sync cleanly to PocketBase without resurrection.
5. **App Lifecycle & Process Stability**: Clean single-instance management and Go engine lifecycle verification on ports 11470/12470.

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

### K. AI Stream Selection Layer in Flux Mode (Architectural Plan)
- **Problem Statement**:
  Heuristics (seed counts, file size thresholds, regex keyword scoring) perform well on standardized releases but suffer on:
  - Cryptic or obfuscated filenames from scrapers (`Dual.Audio`, unlabelled languages, fan edits).
  - Deceptive releases (fake 4K upscales, bloated 60GB uncompressed remuxes on slow swarms, CAM-rips tagged as WEB-DL).
  - Commentary audio tracks mistaken for primary dialogue.
- **Proposed Solution**:
  An intelligent multi-tiered AI layer integrated into Flux Mode auto-play:
  1. **Tier 0 (< 50ms): Heuristic Fast-Path**
     - Instant initial candidate scoring via existing Startup Speed Score (SSS) to begin zero-delay speculative prebuffering.
  2. **Tier 1 (< 5ms): On-Device Semantic Scoring (CoreML / Apple Neural Engine)**
     - Local classification model running on Apple Silicon with 0 network latency.
     - Evaluates feature vector: title similarity, release group reputation, container streamability, audio layout (5.1/7.1 vs stereo), codec efficiency, and seeder density.
     - Predicts playback reliability score $P(\\text{Reliable})$ and audio confidence score.
  3. **Tier 2 (< 350ms): Edge / LLM Reasoning for Ambiguous Candidates**
     - Triggered only when candidate ambiguity is high ($P < 0.70$) or title conflict penalties are encountered.
     - Sends metadata payload to fast inference model (Gemini Flash / PocketBase sidecar) with TMDB item context to pick the true match and best quality compromise.
  4. **Tier 3: Local Failure Learning & Adaptive Feedback**
     - Automatically penalizes release groups or codecs locally when a stream stalls within 15 seconds or requires manual user switching.

---

## 3. Diagnostics & Crash Investigation Notes

### Issue 1: Single-Instance Guard Exit
- **Symptom**: `[flux] Another instance is already running — exiting`
- **Cause**: An earlier debug instance of `flux` was still running in the background. Flux's single-instance guard intentionally terminates newly launched instances to prevent port or state collisions.
- **Resolution**: Check for running processes before launch (`ps aux | grep flux`) and terminate stale instances (`kill -9 <PID>`).

### Issue 2: Data Race in Unit Tests (`UserDataService.renameCollection` / `collectionIDs`)
- **Symptom**: Diagnostic reports `flux-2026-09-23-013616.ips`, `flux-2026-09-23-013614.ips`, `flux-2026-09-23-013607.ips` showed `EXC_BAD_ACCESS` / `swift_retain` on worker threads during `xcodebuild test`.
- **Root Cause**: During app-hosted test runs, concurrent test threads in Swift Testing simultaneously mutated (`renameCollection`) and read (`collectionIDs`) the unisolated `collections` array in `UserDataService`.
- **Immediate Task for New Session**:
  - Mark `UserDataService` or its collection mutation methods with `@MainActor` or introduce an internal `NSLock` / serial isolation around `collections` array operations.

---

## 4. Key Files & Reference Table

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
| **Streaming Engine** | `flux/Engine/FluxEngine` | Embedded Go Stremio core, HTTP 11470, HTTPS 12470 |
| **Player Manager** | `flux/Services/PlayerManager.swift` | MPV playback orchestration, auto-play racing, proxy routing |
| **MPV Video View** | `flux/Views/MPVVideoView.swift` | libmpv wrapper, CAOpenGLLayer rendering, playback properties |

---

## 5. Development & Build Commands

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

## 6. Antigravity Agent Guidelines

When continuing work in Antigravity:
1. **Localization**: Maintain zero hardcoded strings. Every user-visible string must use `.localized` and have 10-language translations in `flux/Services/LanguageManager.swift`.
2. **Push Back on User Requests**: Evaluate trade-offs, warn about regressions, and confirm architectural decisions before proceeding.
3. **Keep `handover.md` Updated**: After finishing any major feature or session, update this document and commit changes.
