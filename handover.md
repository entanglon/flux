# Flux Project Handover & Session Summary

## 1. Overview of Completed Work

### A. Stream Picker Background Isolation & Race Cancellation
- **Problem**: When users clicked "Choose Stream Source…" from detail cards or "Choose Source" / context menus inside the video player, the background Flux Mode Auto-Play engine or early quorum race continued running in the background. Late-arriving streams triggered candidate races and MPV auto-play underneath the stream selection sheet.
- **Root Cause**:
  1. `PlayerManager.fetchAndRace`: The post-fetch Flux Mode auto-play engine and early quorum race commit lacked guards against `forceStreamPicker` and `isStreamPickerPresented`.
  2. The manual stream selection buttons failed to stop active MPV sessions or cancel in-flight scraper/probe background tasks.
- **Implementation**:
  - Added `PlayerManager.cancelAllPlaybackAndRaces()` to cancel `fetchAndRaceTask`, `startupWatchdogTask`, reset `hasCommittedAutoPlayWinner = false`, `isAutoPlayRaceActive = false`, clear `currentStreamURL`, and stop the active MPV player session.
  - Added checks for `!self.forceStreamPicker && !self.isStreamPickerPresented` across all race gates, early quorum commits, and `raceBestStream`.
  - Wired `cancelAllPlaybackAndRaces()` and `mpv.stop()` into the "Choose Source" error button, the right-click "Select Stream Source…" menu, and `PlayerManager.play(_:forceStreamPicker: true)`.

### B. "Choose Source" Button Layout Optimization
- **Problem**: The playback issue dialog (width: 480pt) displayed an overlong `"Choose Another Source"` button that wrapped into two lines, looking distorted and paragraph-like.
- **Implementation**:
  - Replaced label with `"Choose Source".localized` in `PlayerView.swift`.
  - Added `.lineLimit(1)` and `.fixedSize(horizontal: true, vertical: false)` to guarantee a single-line pill button.
  - Added translations for `"Choose Source"`, `"No HTTP streams available for this title"`, and `"Show Torrent Sources"` across all 10 supported languages in `LanguageManager.swift`.

### C. Multi-Token Title Conflict Penalty & Scraper Diagnosis
- **Investigation**:
  - Live testing for *Law & Order* S01E02 (`tt0098844:1:2`):
    - PenguPlay hosts (VidFast, Cinejoy, VAPlayer) were returning HTTP 500/502 errors or timing out.
    - CineFreak returned HTTP 200, but scraped an unrelated show: *"The First Order S01E01-05 WEB-DL Hindi ORG"*.
    - Previously, `StreamManager.evaluateTitleMatch` accepted any single token match (`"order"`), confirming "The First Order" as "Law & Order".
  - PenguPlay server status:
    - Popular cached titles (*Breaking Bad*) return streams.
    - Niche/older titles and unauthenticated endpoints return "You must sign in" or experience timeouts.
- **Implementation**:
  - Updated `StreamManager.evaluateTitleMatch`: 2-word titles (like "Law & Order") require complete token matches; conflicting candidates with $\le 50\%$ coverage receive an explicit conflict disqualification penalty (`-30,000.0`).
  - Updated `PlayerView.streamSelectionView`: When in HTTP mode and 0 HTTP streams exist but torrent streams do exist, the empty state displays a clear indicator and a one-click **"Show Torrent Sources"** button.

### D. Multi-Language Audio Preference Ranking & Secondary Languages
- Multi-language preference arrays stored in `UserDefaults.Key.preferredStreamLanguages`.
- `StreamManager.selectFastStartCandidate` rewards primary language (+5,000), secondary languages (+4,200), and authentic original language (+2,500), while penalizing unmatching foreign dubs (-3,500).
- Settings UI supports selecting and reordering multiple preferred audio languages.
- Fallback preserves foreign dubs as viable backup options if no preferred audio streams succeed.

### E. Stream Playback Pipeline Diagnostics & MPV Loadfile Fix
- **Diagnostic Findings**:
  1. *MPV Syntax Error*: `command("loadfile", url, "replace", "pause=yes")` failed because argument 3 is an integer index in the mpv C API (`[MPV LOG] main: The loadfile option must be an integer: pause=yes`). Prefetched streams failed to prime.
  2. *Demuxer Socket Drops*: When `http-proxy` was set directly on MPV, ffmpeg’s internal TLS CONNECT tunnel dropped sockets during MKV container header seeking (`ffmpeg: httpproxy: Error reading HTTP response: Immediate exit requested`, `Cache: 0.0s/13KB`).
  3. *Proxy Bandwidth Ceiling*: Tailscale Tinyproxy endpoint (`100.73.223.33:8888`) has peak throughput of ~1.1 MB/s (~8.9 Mbps). High-bitrate 1080p HEVC streams (~8–9 Mbps) consumed nearly 100% of bandwidth, causing buffering stalls.
- **Implementation**:
  - In `MPVVideoView.swift`: Fixed `loadfile` invocation by setting `mpv_set_property_string(mpv, "pause", paused ? "yes" : "no")` followed by `command("loadfile", url.absoluteString)`.
  - In `StreamProxyManager.swift`: Made headers optional in `proxyURL(for:headers:title:)` so direct HTTP streams requiring forward proxying can be wrapped by local loopback server (`127.0.0.1:51547`).
  - In `PlayerManager.swift`: Routed forward-proxied HTTP streams through `StreamProxyManager` to isolate MPV from direct TLS proxy seeking issues.
  - Dynamically extended candidate probe timeouts (4.5s) and watchdog timeouts (`connectTimeout: 20s`, `slowLimit: 14s`) when streams are proxied.

### F. Startup Deadlock Resolution & Stremio Co-existence
- **Crash Diagnosis**:
  - Crash report `flux-2026-09-22-235358.ips` showed `EXC_BREAKPOINT / SIGTRAP` in `_dispatch_once_wait`.
  - Circular lock between `AddonManager.shared` and `StreamRouteProxyManager.shared` on Thread 0 during launch:
    `AddonManager.init()` -> `ensureDefaultAddons()` -> `StreamRouteProxyManager.shared.isEnabled = effective` -> `isEnabled.didSet` -> `syncWithStockAddon()` -> synchronous `AddonManager.shared` access.
- **Resolution**:
  - In `AddonManager.swift`: Inlined `addons[existingIdx].isEnabled = StreamRouteProxyManager.shared.isEnabled` without mutating `StreamRouteProxyManager` during singleton construction.
  - In `StreamRouteProxyManager.swift`: Guarded endpoint auto-migration with `!AppEnvironment.isRunningTests` to isolate unit test runs.
  - Verified Stremio app co-existence: Flux uses dynamic port stepping (`11470` through `11479`), gracefully stepping to the next open port if Stremio desktop is already occupying `11470`.

### G. AI Stream Selection Layer in Flux Mode (Architectural Plan)
- **Problem Statement**:
  Heuristics (seed counts, file size thresholds, regex keyword scoring) perform well on standardized releases but suffer on:
  - Cryptic or obfuscated filenames from scrapers (`Dual.Audio`, unlabelled languages, fan edits).
  - Deceptive releases (fake 4K upscales, bloated 60GB uncompressed remuxes on slow swarms, CAM-rips tagged as WEB-DL).
  - Commentary audio tracks mistaken for primary dialogue.
- **Proposed Solution**:
  An intelligent multi-tiered AI layer integrated into Flux Mode auto-play:
  1. **Tier 0 (< 50ms): Heuristic Fast-Path**
     - Instant initial candidate scoring via existing Startup Speed Score (SSS) to begin zero-delay speculative pre-buffering.
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

## 2. Test Suite & Build Verification

- **Full Unit Test Suite**: **225 tests passed, 0 failed, 0 skipped** (`225 passed, 0 failed`).
  - `StreamRouteProxyTests`: All tests passing including `defaultStateHasNoEndpointAndDoesNotProxy`, `stockAddonRegistrationAndSynchronization`, `cloudSyncPreservesLocallyEnabledProxy`.
  - `StreamManagerTests`: All 45+ stream selection and scoring tests passing.
  - `ArchitectureTests`, `LanguageManagerTests`, `KidsContentFilterTests`, `SearchEngineTests`: All passing.
- **App Status**: Rebuilt and running stably under Debug scheme (PID `81626`).
- **No Diagnostic Crashes**: Zero crash reports generated post-fix.

---

## 3. Files Modified
- `STREAMING_PIPELINE_PLAN.md`: Added Pillar E (AI-Powered Stream Selection Layer) and Step 6 to implementation roadmap.
- `handover.md`: Updated with playback diagnostics, MPV loadfile fix, circular deadlock resolution, Stremio co-existence verification, and AI stream selection plan.
- `flux/Services/AddonManager.swift`: Decoupled stock addon initialization from `StreamRouteProxyManager` setter to eliminate circular `dispatch_once` deadlock.
- `flux/Services/StreamRouteProxyManager.swift`: Guarded endpoint auto-migration with `!AppEnvironment.isRunningTests`; restored clean main-thread synchronization.
- `flux/Services/StreamProxyManager.swift`: Supported optional headers in `proxyURL` for HTTP scraper streams.
- `flux/Services/PlayerManager.swift`: Routed forward-proxied HTTP streams through `StreamProxyManager`; tuned startup watchdog timeouts for proxied streams.
- `flux/Views/MPVVideoView.swift`: Fixed MPV `loadfile` pause syntax (`mpv_set_property_string(mpv, "pause", ...)`).
- `flux/Services/StreamManager.swift`: Dynamic candidate probe timeouts for forward proxying.
