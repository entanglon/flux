# Flux — Codebase Evaluation

## 1. Project Overview

**Flux** is a native macOS media center built with SwiftUI, targeting macOS Sonoma 14.0+. It lets users browse, manage, and play movies/TV shows using TMDB metadata and Stremio-compatible streaming backends. The app features a premium "Glass" aesthetic and includes a custom player built on `libmpv`.

| Metric | Value |
|---|---|
| **Language** | Swift (SwiftUI) |
| **Total Swift source files** | 82 |
| **Total lines of Swift** | ~17,361 |
| **Targets** | `flux` (app), `fluxTests`, `fluxUITests` |
| **Dependencies (SPM)** | MPVKit (GPL), Firebase iOS SDK |
| **Backend** | Cloudflare Worker + D1 (JS/SQL) |

---

## 2. Architecture — Strengths

### ✅ Well-Organized Directory Structure
```
flux/
├── Components/   (23 files — reusable UI components)
├── Extensions/   (2 files)
├── Models/       (12 files — data models)
├── Services/     (19 files — business logic)
├── Views/        (23 files — screens + Auth/Profile subdirs)
├── fluxApp.swift (entry point)
└── ContentView.swift (main shell)
```
Clean separation of concerns: Views, Components, Services, Models, and Extensions are properly isolated.

### ✅ Modern Navigation Architecture
Value-based `NavigationLink(value:)` with `.navigationDestination` handlers centralized in `ContentView.swift`. This is the correct modern SwiftUI pattern and avoids the deprecated destination-based approach (which was historically a bug source, as documented in `handover.md`).

### ✅ Sophisticated Prefetch & Warm-Core System
`PlayerManager` implements a genuinely impressive prefetch pipeline:
- Detail page opens → streams are pre-fetched
- In "Flux Mode", a warm `mpv` core is built holding a paused stream, ready for instant playback
- Warm cores have a 5-minute TTL with automatic discard
- Torrent ownership tracking prevents double downloads

### ✅ Robust Process Management
`StremioServerManager` is production-quality:
- Exponential backoff for relaunches
- Rolling-window crash cap (5 failures in 60s → failed state)
- Transparent replay of active torrent registrations after restart
- Stale engine cleanup via `pkill`
- Self-provisioning of Node.js runtime if not installed

### ✅ ContentView is Clean & Focused
`ContentView.swift` is **331 lines** — clean, focused, and well-decomposed. The sidebar, navigation shell, and window configuration are properly scoped.

### ✅ Memory-Conscious Design
The codebase shows deliberate memory management:
- Bounded NSCache (80 items / 30MB)
- Bounded URLCache (32MB memory / 512MB disk)
- LRU eviction on in-memory TMDB caches
- Background image downsampling via `Task.detached`
- FluxEngine constrained to `GOMEMLIMIT=500MB`, `GOGC=20`

---

## 3. Architecture — Concerns

### ⚠️ Heavy Singleton Reliance (16 of 19 services)
Every service uses `static let shared` — nearly 100% singleton pattern with no dependency injection:

```swift
PlayerManager.shared, StremioServerManager.shared, TMDBEnricher.shared,
StreamManager.shared, AuthManager.shared, UserDataService.shared,
ProfileManager.shared, SearchManager.shared, SubtitleManager.shared,
PiPManager.shared, DownloadManager.shared, StreamProxyManager.shared,
AddonManager.shared, TasteProfileManager.shared, RecentSearchManager.shared,
FluxCloudClient.shared
```

**Impact**: Tight coupling, impossible to unit test services in isolation, and no protocol abstractions. There are **zero `protocol` definitions** in the entire codebase for service contracts.

### ⚠️ No Accessibility Support
Zero accessibility labels, hints, or VoiceOver annotations across all 82 Swift files. This is a significant gap for a macOS app.

### ⚠️ No Localization
Zero use of `NSLocalizedString`, `LocalizedStringKey`, or `String(localized:)`. All UI strings are hardcoded English.

### ⚠️ Excessive `print()` Debugging
60+ `print()` statements across services (`PlayerManager`: 31, `StremioServerManager`: 29). No structured logging framework (e.g., `os.Logger`). The `ImageDebugLog` writes to `/tmp/flux_image_debug.log` — fine for development, but a filesystem-writing logger should be behind a debug flag in production.

### ⚠️ Scattered UserDefaults Keys (77 call sites)
`UserDefaults.standard` is accessed 77 times across the codebase with raw string keys like `"enableFluxMode"`, `"streamingSourceMode"`, `"stremioCacheGB"`, `"lastUsedSource"`, etc. No centralized key registry or type-safe wrapper.

### ⚠️ Missing Error Types
Most services swallow errors with `try?` or return `nil`. There's no domain-specific error enum for streaming, playback, or TMDB failures. `AuthManager` is the only service with meaningful error propagation.

---

## 4. Testing — Critical Gap

| Test Suite | Files | Tests | Coverage |
|---|---|---|---|
| `fluxTests` | 1 | 2 tests (image cost calculation) | <1% |
| `fluxUITests` | 2 | Xcode template stubs only | 0% |

**Assessment**: Testing is essentially non-existent. The 2 unit tests cover only `ImageInMemoryCache.decodedImageCost`. No tests exist for any of:
- `PlayerManager` (1,097 lines of complex state management)
- `StreamManager` (stream parsing, caching, URL construction)
- `TMDBEnricher` (API response parsing, caching)
- `AuthManager` (sign in/up flows, sync logic)
- `StremioServerManager` (port discovery, process management)
- Navigation routing, data persistence, cloud sync

---

## 5. Code Quality By File

### Largest/Most Complex Files

| File | Lines | Assessment |
|---|---|---|
| `PlayerManager.swift` | 1,097 | **High complexity, well-structured.** Clear MARK sections, good comments explaining Stremio protocol. Could benefit from extracting `WarmCoreManager` and `StreamRacer` sub-objects. |
| `DetailView.swift` | 1,008 | **Large but reasonable for a detail page.** Has 1 TODO left ("Implement Mark Watched"). |
| `MPVVideoView.swift` | 1,007 | **Necessarily complex** (mpv C-interop, render callbacks). 2 `fatalError` for `init(coder:)` — acceptable for programmatic-only views. |
| `PlayerView.swift` | 825 | **Complex player UI.** Heavy nesting for controls overlay logic. |
| `StremioServerManager.swift` | 618 | **Excellent quality.** Thorough error handling, well-documented supervisor pattern, cache eviction. |
| `TMDBEnricher.swift` | 611 | **Solid.** Thread-safe caching with `NSLock`, bounded LRU, graceful degradation when no API key. |
| `StreamManager.swift` | 549 | **Good.** Proper timeout configuration, bounded cache, lock-based synchronization. |

### Patterns Worth Noting

**Positive:**
- `typealias AsyncTask = _Concurrency.Task` — avoids `Task` name collision cleanly
- Proper structured concurrency with `withTaskGroup`
- `Stream.stableKey` prevents UUID churn across refetches
- Client-side firewall validating torrent info hashes before they reach the engine

**Concerning:**
- `Secrets.swift` ships Trakt client ID and secret in plain text (tracked in `.gitignore` but file is present)
- `DispatchQueue.main.async` mixed with `@MainActor` and `await MainActor.run` — inconsistent concurrency model
- `NSLock` used alongside Swift concurrency (no `actor` types anywhere)

---

## 6. Dependencies & Build

### SPM Dependencies
1. **MPVKit (GPL)** — libmpv player bindings
2. **Firebase iOS SDK** — imported but currently commented out (`// import FirebaseCore`). Firebase Auth has been replaced by the Cloudflare Worker backend, but the SPM reference remains.

### Backend
- **Cloudflare Worker** (Wrangler) with D1 SQLite database
- Handles auth (PBKDF2 hashing, HMAC-signed JWTs, throttling)
- Single JSON blob sync per user for library data
- Clean schema with proper foreign keys and indexes

### Build & Release
- Xcode 15.0+ required
- Release build produces a 100MB app / 40MB DMG (`Flux.dmg` in repo — should probably be in Releases, not the repo)
- Scripts for creating xcframeworks (MoltenVK, mpvkit-legacy)
- No CI/CD pipeline configured (no `.github/workflows`, Fastlane, etc.)

---

## 7. Documentation — Good

| Document | Purpose | Quality |
|---|---|---|
| `README.md` | Setup guide, tech stack | ✅ Clear and complete |
| `handover.md` | Session journal with architecture diagram | ✅ Excellent — detailed fix histories with root causes |
| `task.md` | Active session journal | ✅ Good — duplicates some handover content |
| `ROADMAP.md` | Cascade addon plan | ✅ Thoughtful architecture sketch |
| `RAM_MANAGEMENT_PLAN.md` | Memory budget | ✅ Thorough |
| `CONTRIBUTING.md` | Contribution guide | ✅ Present |
| `DISCLAIMER.md` | Legal disclaimer | ✅ Present |

The `handover.md` is genuinely impressive — each bug fix documents root cause, diagnosis method, and exact fix. This is excellent institutional knowledge.

---

## 8. Security Observations

| Item | Status |
|---|---|
| Auth tokens stored in `UserDefaults` (not Keychain) | ⚠️ `UserDefaults` is not encrypted |
| `Secrets.swift` contains Trakt API keys in plaintext | ⚠️ Should use Keychain or env vars |
| API key passed as URL query parameter (`?api_key=`) | ⚠️ May appear in logs/caches |
| `KeychainStore.swift` exists but isn't used for auth tokens | ⚠️ Inconsistent |
| Client firewall validates torrent hashes | ✅ Good input validation |
| Backend uses PBKDF2 + HMAC-signed JWTs | ✅ Sound auth design |

---

## 9. Summary Scorecard

| Dimension | Rating | Notes |
|---|---|---|
| **Architecture** | ⭐⭐⭐⭐ | Clean separation, sophisticated streaming pipeline |
| **Code Quality** | ⭐⭐⭐⭐ | Well-commented, consistent style, few unsafe patterns |
| **Testing** | ⭐ | Essentially untested — biggest risk |
| **Accessibility** | ⭐ | Zero support |
| **Localization** | ⭐ | English only, no framework |
| **Security** | ⭐⭐⭐ | Auth is solid; token storage and secret management need work |
| **Documentation** | ⭐⭐⭐⭐⭐ | Exceptional handover docs and architecture notes |
| **Dependency Management** | ⭐⭐⭐ | Clean SPM, but stale Firebase reference |
| **CI/CD** | ⭐ | None configured |
| **Performance** | ⭐⭐⭐⭐ | Deliberate memory budgeting, background decoding, bounded caches |

---

## 10. Top Recommendations (prioritized)

1. **Add unit tests** — especially for `PlayerManager`, `StreamManager`, and `TMDBEnricher`. Extract protocols for services to enable test doubles.
2. **Set up CI/CD** — even a basic GitHub Actions workflow for build verification.
3. **Move auth tokens to Keychain** — `KeychainStore.swift` already exists.
4. **Replace `print()` with `os.Logger`** — structured, filterable, zero cost when not debugging.
5. **Centralize UserDefaults keys** — single enum/struct with typed accessors.
6. **Remove stale Firebase SPM dependency** — it's commented out but still pulled.
7. **Add basic accessibility** — `.accessibilityLabel` on all interactive elements.
8. **Introduce protocol abstractions** — at minimum for network-dependent services to enable testability.

---

*Evaluated: August 2026*
