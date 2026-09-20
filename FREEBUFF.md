# Freebuff — Agent Instructions & Project Guidelines

> **Project**: Flux (macOS Desktop Streaming & Media Management Application)  
> **Target OS**: macOS 14.0+ (Apple Silicon & Intel)  
> **Language & UI**: Swift 5.10 / SwiftUI  
> **Video Engine**: Native `libmpv` via `LocalMPVKit` + `CAOpenGLLayer`  
> **Streaming Engine**: Embedded Go `FluxEngine` Stremio daemon on loopback HTTP/HTTPS (ports 11470 and 12470)  
> **Metadata**: TMDB API + Stremio Addon manifest bridge  
> **Cloud Sync**: PocketBase backend for cross-device watchlist, watch progress, profile sync, and search history  

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
