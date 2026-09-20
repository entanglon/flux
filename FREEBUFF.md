# Freebuff — Agent Instructions & Project Guidelines

> **Project**: Flux (macOS Desktop Streaming & Media Management Application)  
> **Target OS**: macOS 14.0+ (Apple Silicon & Intel)  
> **Language & UI**: Swift 5.10 / SwiftUI  
> **Video Engine**: Native `libmpv` via `LocalMPVKit` + `CAOpenGLLayer`  
> **Streaming Engine**: Embedded Go `FluxEngine` Stremio daemon on loopback HTTP/HTTPS (ports 11470 and 12470)  
> **Metadata**: TMDB API + Stremio Addon manifest bridge  
> **Cloud Sync**: PocketBase backend for cross-device watchlist, watch progress, profile sync, and search history  

---

## ACTIVE: Junk-Brand Label Detection + Replay Gate (Sep 20, evening)
- **Incident**: Coyote vs. Acme auto-played the MovieBox promo trailer; manual pick played fine. Root cause: junk scan checked URL/filename/Referer but NEVER the scraper label (`stream.title` / `stream.source`) — scrapers brand promos "Coyote vs. Acme MovieBox promo trailer" behind opaque CDN tokens the filename scanner can't analyze, and a junk CDN measures *fastest* (no congestion).
- **Fix**: `StreamManager.labelLooksLikeJunk(labelText:targetTitle:)` — shared static detector (label junk tokens incl. moviebox; target-title words subtracted so "Trailer Park Boys" stays safe). Used by `evaluateTitleMatch` (→ −15,000, runs before foreign-title immunity) and by a new `cachedStreamLabelLooksLikeJunk` gate on BOTH instant-replay paths in `play()` — a HEAD health check passes instantly against a promo CDN, so labels are the only reliable replay signal.
- **Tests**: `evaluateTitleMatchDemotesJunkBrandedSourceBehindOpaqueToken`, `labelLooksLikeJunkGuardsReplayGate` — suite at 194/194.
- **Do not**: scan `stream.source` for conflict logic (labels are scraper noise for title matching — junk detection only); gate the replay paths on URL health alone ever again.

## ARCHIVED: Measured Source Racing & Hot-Swap (Sep 20, evening)
- **Design**: hybrid "measure, then commit" — parallel 512KB ranged-GET probes (3s hard cap) over the top HTTP shortlist in `StreamManager.raceThroughput`; first candidate sustaining ≥800KB/s commits early (after better-ranked rivals measured slower), else best-measured wins the re-rank. Full parallel-mpv racing deliberately rejected (bandwidth self-competition distorts the measurement; N×~60MB RAM).
- **Ranking invariant**: for probed HTTP streams, MEASURED throughput replaces the paper SSS (+5000 cap) in `computeCompositeRank` — never add both. ≥800KB/s → +3500…+5500; 170–800 → linear; <170 → −4000; hijacked (HTML/JSON/tiny non-media probe bodies) → ok=false + −25000. Torrents are never HTTP-probed.
- **Hot-swap safety nets**: pre-start slow-delivery watchdog (<1.5s media after 8s HTTP / <1.0s after 14s torrent) and post-start monitor (first 30s, <15s watched, buffer <4s, mpv `cache-speed` <100KB/s sustained ×2 strikes → `advanceToStandbyFallback`). The watchdog now survives playback start (`markPlaybackStarted` no longer cancels; `reportTelemetryProgress` no longer cancels at 1.5s cache) and exits on its own at window expiry.
- **Do not**: reintroduce unbounded HEAD probes (they hang on HEAD-blocking CDNs — ranged GETs + hard time-box are mandatory), or route probes anywhere but the real delivery path (loopback proxy + headers included).
- **mpv contract unchanged**: only read-only `cache-speed` observation added (`recentCacheSpeedKBps`); zero engine option changes.

## RESOLVED (Sep 20, later): Wrong Content & Wrong Audio (3 Idiots / Family Guy)
- **Refined incident report**: Flux Mode was not hanging for the user — it played wrong things. *3 Idiots* opened with English directors'-commentary audio (user read it as "a review"); *Family Guy* played a MovieBox-style intro video; sources buffer.
- **Audio hijack root cause**: `autoSelectPreferredTracks` matched preferred language (English), and when every preferred-language match was commentary, the `?? matching.first` fallthrough picked the commentary track anyway. Original-language ladder was only consulted when no preferred track existed. **Fix**: pure, unit-tested `MPVController.preferredAudioTrack(from:preferredLang:originalLanguage:)` — original-language-first for foreign titles, preferred-language dub only when original is absent, commentary only as last resort.
- **Wrong-content root causes** (diff vs released beta.2 `76395c3`): blanket foreign-title immunity (conflicts never penalized when `originalLanguage != "en"`) + opaque-token URLs excluded from title analysis. **Mitigation shipped**: curated junk-token demotion in `evaluateTitleMatch` (−15,000 in title portion / −6,000 after the S/E marker; target-title words exempt) + size sanity in `computeCompositeRank` (advertised < 50MB episode / < 150MB movie → −8,000; unknown sizes never punished).
- **Tests**: 188/188 green (8 new: 4 audio-selection, 4 junk/size).
- **Do not re-fix**: the 1080p cap is already user-configured and strictly enforced in `selectFastStartCandidate`.
- **Open roadmap (agreed)**: (1) measured ranged-GET racing to fix buffering; (2) TMDB `original_title` on `MediaItem` for precise foreign conflict detection; (3) instant-replay paths in `play()` still bypass the startup watchdog and skip torrent re-registration on the engine.

## RESOLVED: Flux Mode Stall / No-Auto-Advance (Sep 20, 2026)
### Incident: *My Name is Khan* Flux Mode Playback Failure vs Manual Source #2 Success — ROOT-CAUSED & FIXED
- **Symptom**: Flux Mode auto-play stalled at 00:00 (Candidate #1 `proxied=true`, PenguPlay), while the manually picked Source #2 (`proxied=false`) played instantly. Generalized to most titles after the first successful playback of a session.
- **Root Causes (3 stacked defects, all fixed)**:
  1. **Stale `hasPlaybackStarted`**: set `true` by `markPlaybackStarted()` and never reset — after the first successful title, `attemptStream`'s startup watchdog bailed out instantly (`if self.hasPlaybackStarted { return false }`) and never auto-advanced. Now reset in `play()` and at the top of every `attemptStream`.
  2. **Prefetch fast path had no watchdog at all**: `fetchAndRace`'s prefetch hit commits via `finishSelect(pf)` without `attemptStream`. Watchdog extracted into `armStartupWatchdog(for:)` and armed there too.
  3. **Autoplay ranker ignored host reputation**: `computeCompositeRank` never subtracted `HostHealthTracker.penalty`, and failed HTTP hosts were never recorded. Ranker now applies the penalty; `advanceToStandbyFallback` records a strike (+ failed probeStatus) for the failed HTTP origin. Regression test: `selectFastStartCandidateDemotesHostsWithRecentFailures`.
- **Expected behavior now**: a stalled candidate auto-advances within ~14s (HTTP connect timeout) or ~10s after bytes stop flowing, instead of hanging forever. Verify via unified log `⏱️` watchdog lines and `⚡ Seamlessly advancing to standby fallback` entries.
- **Do not re-investigate the proxy first**: `StreamProxyManager` (watermarks, silent resume) was audited and is healthy; the hang was the disarmed watchdog + unrecorded host failures, not the pipe.

---

## 1. MANDATORY: Localization-First Development
Whenever creating or modifying any user-facing UI in Flux (views, sheets, alerts, settings, navigation items, buttons, badges, diagnostic overlays, menus, or error messages):
1. **Zero Hardcoded Strings**: Every user-visible string must use `.localized` or `String.localizedFormat(...)` / `"...".localizedFormat(...)`. Never render raw English string literals directly in SwiftUI views.
2. **10-Language Matrix**: Whenever introducing a new key, add corresponding translations across all 10 supported languages (`en`, `ja`, `es`, `fr`, `de`, `it`, `pt`, `ko`, `hi`, `zh`) in `flux/Services/LanguageManager.swift`.
3. **CRITICAL — Guard Against Duplicate Dictionary Keys**: Swift does not detect duplicate keys in dictionary literals at compile time, but throws a fatal crash at runtime during app launch (`Fatal error: Dictionary literal contains duplicate keys`). Always verify keys are strictly unique before building or committing.
4. **Preserve Internal Keys in Canonical English**: TMDB API parameters/genres, Stremio addon IDs/types (`movie`, `series`, `channel`), PocketBase schema fields, and UserDefaults system keys must remain canonical English. Only user-facing display text is localized.
5. **Dynamic Language Observation**: Views must observe `LanguageManager.shared` (e.g., `@ObservedObject var languageManager = LanguageManager.shared`) so changing language in Settings (`⌘,`) dynamically updates the view in real-time without requiring an app restart.

---

## 2. MANDATORY: Push Back on User Requests
When the user requests a change, DO NOT implement it blindly:
1. **Evaluate the request**: Is it the right fix? Could the user be misidentifying a bug that's actually intended behavior or an architectural constraint?
2. **Warn about consequences**: What will break? What trade-offs exist? What's lost?
3. **Suggest alternatives**: If the proposed fix has downsides, propose a cleaner, more robust approach.
4. **Ask before proceeding**: "Are you sure? Here is what will happen if we do this..."

---

## 3. Streaming Engine & Flux Mode Rules

### Zero Language Bias When Filter is Disabled
- The user setting "Language Filter in Flux Mode" (`enableFluxLanguageFilter == 0` / `false`) governs scraper-level stream ranking.
- When this filter is **OFF**, `StreamManager.computeCompositeRank` must apply **ZERO language scoring, zero language bonuses, and zero language gating**. Streams are ranked strictly by quality cap, stream health, seeders, and startup speed.
- In-player audio track auto-selection (`MPVVideoView.autoSelectPreferredTracks`) operates at the player level after container demuxing, switching to the user's preferred audio language if present in the playing file.

### Foreign Title Anti-Mismatch Protection
- Foreign media releases (Anime, Bollywood/Indian cinema, K-Dramas, European films) frequently use native or romanized titles in filenames (e.g. *Hey! Sinamika*, *Chup*, *Kurup*, *Demon Slayer / Kimetsu no Yaiba*, *Crash Landing on You / Sarangui Bulsichak*).
- `StreamManager.evaluateTitleMatch` must **never** apply the `-30,000.0` mismatch penalty when `originalLanguage != "en"`.
- Opaque CDN tokens (such as PenguPlay `/direct/external/<encrypted_token>`) must be recognized via `isOpaqueToken(_:)` and ignored during title conflict analysis.

### Fast Start & Auto-Fallback
- Flux Mode commits immediately (sub-5ms) to candidate #1 without blocking network probes, keeping standby fallbacks ready.
- If a stream stalls or fails during playback, `PlayerManager.advancePast(failed:)` auto-advances to the next candidate matching by `stableKey` (`$0.stableKey == failed.stableKey || $0.id == failed.id`).

---

## 4. Build, Test, & Execution Commands

### Clean Build
```bash
xcodebuild -project flux.xcodeproj -scheme flux -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO build -quiet
```

### Run Entire Test Suite
```bash
xcodebuild test -scheme flux -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -quiet
```

### Run StreamManager Tests (Fast Subset)
```bash
xcodebuild test -scheme flux -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:fluxTests/StreamManagerTests
```

### Restart App with Newly Compiled Binary
```bash
killall flux FluxEngine 2>/dev/null || true
open /Users/zainulnazir/Library/Developer/Xcode/DerivedData/flux-bsqlajoncxxaywbmbbeyxatsxjrp/Build/Products/Debug/flux.app
```

### Check Running Processes
```bash
pgrep -fl "flux|FluxEngine"
```

---

## 5. Architectural Directory Map

| Path | Purpose |
| :--- | :--- |
| `flux/Services/StreamManager.swift` | Stremio addon stream scraping, composite ranking (`computeCompositeRank`), Fast Start selection (`selectFastStartCandidate`), title validation (`evaluateTitleMatch`), language filtering. |
| `flux/Services/PlayerManager.swift` | Playback orchestration, auto-fallback on stall (`advancePast`), probe status tracking, buffer monitoring. |
| `flux/Views/PlayerView.swift` | Native borderless floating player window, traffic light fade controls, libmpv rendering via `MPVVideoView`. |
| `flux/Services/LanguageManager.swift` | 10-language localization matrix (`en`, `ja`, `es`, `fr`, `de`, `it`, `pt`, `ko`, `hi`, `zh`). |
| `flux/Services/StremioService.swift` | Bridge to local Go `FluxEngine` Stremio daemon on loopback ports 11470 and 12470. |
| `flux/Services/AuthManager.swift` | PocketBase cloud authentication and auto-sync triggers. |
| `flux/Services/ProfileManager.swift` | Profile switching and cloud profile export/import. |
| `flux/Services/RecentSearchManager.swift` | Profile-scoped search history with `!AppEnvironment.isRunningTests` protection. |
| `handover.md` | Active session journal. **Always consult at the start of a session and update at the end.** |

---

## 6. Test Safety Invariant
- Unit tests must **NEVER** wipe production or local development data.
- Any methods resetting preferences, signing out users, or clearing caches must be guarded with:
  ```swift
  guard !AppEnvironment.isRunningTests else { return }
  ```
