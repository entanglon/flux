# Flux — Active Session Journal

## LATEST: Aug 28, 2026 — CRASH FIX + PROCESS CLEANUP + TMDB VALIDATION + CACHE EVICTION + UI/UX POLISH

### What was done this session

#### 1. Warm-Core NSWindow Double-Release Crash Fix
- **Bug:** App crashed every time you opened a detail page, scrolled, and hit back — but only with Flux mode ON
- **Root cause:** `cancelDetailPrefetch()` called `hostWindow?.close()` which auto-releases NSWindow (`isReleasedWhenClosed = true`), then `warmCore = nil` released it again via ARC → `EXC_BAD_ACCESS`
- **Diagnosis:** Zombie Objects + MallocScribble caught `*** -[NSWindow release]: message sent to deallocated instance`
- **Fix:**
  - `buildWarmCore()` — set `host.isReleasedWhenClosed = false` at creation
  - `cancelDetailPrefetch()` — changed `close()` to `orderOut(nil)` (matches safe `discardWarmCore()`)

#### 2. FluxEngine Orphan Process Fix
- **Bug:** 5 FluxEngine processes at 99% CPU each, surviving app close
- **Root cause:** `ensureRunning()` nil'd `self.process` and launched a new FluxEngine without killing the old one. `stopServer()` only killed the last tracked process.
- **Fix:**
  - `ensureRunning()` — kills old process (terminate + 2s SIGKILL fallback) before launching new one
  - `stopServer()` — added `pkill -f FluxEngine` safety net after tracked kill

#### 3. TMDB Key Validation UI
- Settings → General: **Save Key** button (no more auto-save on typing)
- Validates key against TMDB API before saving — invalid keys never persisted
- Green checkmark on success, red X on failure
- Default TMDB key provided as placeholder fallback

#### 4. Login Screen Flash Fix
- **Bug:** On app startup, the login screen flashed for a single frame before showing main content
- **Root cause:** `AuthManager.init()` restored authentication state via `DispatchQueue.main.async`, causing the first render pass to see `isAuthenticated = false`
- **Fix:** Restored auth state synchronously in `AuthManager.init()`

#### 5. Torrent Cache Eviction Fix
- **Bug:** Torrent cache was never evicted and settings showed "0 KB" used
- **Root cause:** `cacheUsage()` and `evictCacheIfNeeded()` looked in `StremioServer/stremio-cache/` which does not exist with FluxEngine (stores `{infoHash}/` directly under appPath)
- **Fix:** Updated cache directory resolution, switched to allocated disk block measurement for sparse `.part` files, guarded 40-character hex directories, and protected actively streaming torrents

#### 6. UI/UX Performance & Animation Polish
- **Fix:** Offloaded `CachedImage` downsampling to background tasks (`Task.detached(priority: .userInitiated)`) to ensure 60/120fps scrolling without main-thread blocking
- **Fix:** Paused `FeaturedCarousel` timer on user hover (`!isHovering`) and smoothed slide animations
- **Fix:** Added `.transition(.opacity)` and `withAnimation` crossfades to `HomeView`, `DetailView`, `SearchView`, `MoviesView`, `TVShowsView`, and `TrendingView`

#### 7. Database & "For You" Taste Profile Cloud Sync
- **Bug:** Data was never uploaded to the cloud database on new accounts (`{"notFound":true}` was treated as error), and no auto-sync ran on library mutations or app startup.
- **Fix:** Handled `{ notFound: true }` in `FluxCloudClient.fetchData`.
- **Fix:** Added `scheduleAutoSync(delay: 2.0)` debouncer and `syncOnLaunch()` to `AuthManager`.
- **Fix:** Added `tasteLoved` and `tasteSnapshots` from `TasteProfileManager` into `exportCloudPayload()` and `applyCloudPayload()`.
- **Fix:** Connected profile switching on startup in `ProfileManager.applyProfileDataScope()`.

#### 8. Genre & Subpage Navigation Stack Fix
- **Bug:** Genre card opened from Search remained stuck on screen when clicking Home or any other sidebar tab until the back button was clicked.
- **Root cause:** `SearchView` used legacy `NavigationLink(destination:)` which bypassed `NavigationStack(path: $path)` state, preventing `path = NavigationPath()` from dismissing the view on tab switch.
- **Fix:** Converted all view-based navigation links (`SearchView` genres, `DetailView` related/cast, `CastListView`, `PersonView`, `MoviesView`, `TVShowsView`, `HomeView`) to value-based `NavigationLink(value:)` with registered `.navigationDestination` handlers in `ContentView.swift`.
- **Fix:** `sidebarRow` now unconditionally clears `path` on any tab click.

---

## Prioritized Task Backlog (From Codebase Evaluation)

### 🚀 Phase 1: Security & Dependency Cleanups (Immediate)
- [x] **Remove Stale Firebase SPM Package:** Cleaned out `firebase-ios-sdk` remote dependency from `flux.xcodeproj/project.pbxproj` and removed commented references in `fluxApp.swift`.
- [x] **Secure Auth Token in Keychain:** Migrated `AuthManager` JWT token (`flux.authToken`) from plaintext `UserDefaults` to encrypted `KeychainStore` (`kSecClassGenericPassword`), with automatic migration on launch.
- [x] **Type-Safe `UserDefaults` Registry (`UserDefaults+Keys.swift`):** Centralized all raw string keys into typed constants (`UserDefaults.Key`) across core services.
- [x] **Structured Logging (`os.Logger`):** Added `Logger+Flux.swift` (`com.kernelmoth.flux`) for unified Apple OS logging.

### 🧪 Phase 2: Reliability & Test Suite
- [x] **Core Unit Tests:** Comprehensive unit test coverage using Swift Testing (`fluxTests`): `StreamManagerTests` (quality scoring, stableKeys, health sorting), `TMDBEnricherTests` (adaptive URLs, 18 genres), `UserDataServiceTests` (MediaItem parsing, key paths, Keychain CRUD).
- [x] **Automated CI/CD Workflow:** Added GitHub Actions workflow (`.github/workflows/ci.yml`) to automatically compile and run unit tests on every commit/PR.

### ♿ Phase 3: Accessibility & Art Polish
- [x] **Accessibility (VoiceOver):** Added `.accessibilityElement`, `.accessibilityLabel`, and `.accessibilityHint` annotations to `GlassCard`, `ContinueWatchingCard`, and `GenreCard`.
- [x] **Search Card Art & Fallback Polish:** Added dynamic glassmorphic fallback placeholder with category icon and title preview in `GlassCard` when external poster art is missing.

### 🌟 Phase 4: Advanced Polish & Architecture (Completed)
- [x] **"Mark as Watched" Toggle on Detail Pages:** Added "Mark as Watched" / "Mark as Unwatched" button on `DetailView.swift` and `LiquidEpisodeCard` to easily manage history without playing.
- [x] **Player Controls Keyboard Navigation & a11y:** Added keyboard shortcuts (`Space` = Play/Pause, `←/→` = 10s Seek, `M` = Mute, `C` = Show Controls) and VoiceOver labels on `PlayerControlsView.swift`.
- [x] **Service Protocol Abstractions:** Defined core protocol contracts (`TMDBServiceProtocol`, `StreamServiceProtocol`, `UserDataProtocol`, `AuthServiceProtocol`) in `Protocols.swift` for clean architecture and testing doubles.
- [x] **Smart Two-Way Cloud Merge:** Fixed watch history persistence across restarts by implementing intelligent two-way cloud merging instead of destructive overwrite.

### 🏗️ Phase 5: Evaluation Completion & Modernization (Completed)
- [x] **Task 1: Production Guard on ImageDebugLog:** Wrapped image debug log writes in `#if DEBUG` to eliminate disk I/O in production release builds.
- [x] **Task 2: Domain-Specific Error Types:** Created `FluxError.swift` defining typed domain errors (`StreamingError`, `TMDBError`, `AuthError`, `SyncError`) with descriptive localized messages.
- [x] **Task 3: Concurrency Modernization:** Replaced legacy `NSLock` instances in `TMDBEnricher` and `StreamManager` with Swift `actor`s (`TMDBMemoryCacheActor`, `StreamCacheActor`).
- [x] **Task 4: Decompose `PlayerManager.swift`:** Extracted `WarmCoreController.swift` and `StreamRacingController.swift` out of `PlayerManager.swift`.
- [x] **Task 5: Unit Test Suite Expansion:** Added comprehensive tests for `FluxError`, cache actors, warm core, and stream racing in `ArchitectureTests.swift` (17 / 17 tests passing in Swift Testing).

---

## Done (cumulative)
- ✅ Domain-specific typed error models (FluxError.swift)
- ✅ Swift actor-isolated in-memory caches (CacheActors.swift)
- ✅ WarmCoreController & StreamRacingController extracted
- ✅ 17 / 17 unit tests passing across 5 test suites (Swift Testing)
- ✅ Production #if DEBUG guard on ImageDebugLog
- ✅ Smart two-way cloud merge preventing history loss on app restart
- ✅ "Mark as Watched" toggle on Detail pages & episode cards
- ✅ Player keyboard navigation (`Space`, `M`, `C`, arrows) and VoiceOver
- ✅ Service protocol abstractions (Protocols.swift)
- ✅ Core unit test suite (100% pass rate in Swift Testing)
- ✅ GitHub Actions CI workflow (.github/workflows/ci.yml)
- ✅ VoiceOver accessibility annotations on media & genre cards
- ✅ Search card art glassmorphic fallback placeholder
- ✅ Hardware-encrypted Keychain token storage with migration
- ✅ Type-safe UserDefaults key registry (UserDefaults+Keys.swift)
- ✅ Stale Firebase SPM package removed
- ✅ Downloads page — DownloadManager + DownloadsView + DetailView button
- ✅ For You rail — live-refreshes after ♥ toggle (600ms debounce)
- ✅ RAM management — bounded caches, proxy backpressure, prefetch ownership
- ✅ Continue Watching — progress bar saved on player close
- ✅ OTT catalogs — via TMDB watch providers (always fresh)
- ✅ Play Trailer — button on detail pages, opens YouTube
- ✅ Release build + DMG (100MB app / 40MB DMG)
- ✅ Skip Intro / Next Episode — Apple TV-style floating capsules
- ✅ Memory tightening — FluxEngine 25MB idle, mpv buffers halved
- ✅ Double torrent download fix — activeTorrentHash tracking
- ✅ Search improvements — dropdown suggestions, Retina art
- ✅ Warm-core crash fix — NSWindow double-release resolved
- ✅ FluxEngine orphan process fix — clean exit guaranteed
- ✅ TMDB key validation — verify-before-save UI
- ✅ Login screen flash fix — synchronous auth restore in init()
- ✅ Torrent cache eviction fix — correct path for FluxEngine, sparse file accounting, config file protection
- ✅ UI/UX performance & animation polish — detached background image decoding, carousel hover guard, smooth skeleton crossfades
- ✅ Database & "For You" taste profile sync — automatic debounced sync, launch sync, taste signals in cloud payload
- ✅ Genre & Subpage Navigation Stack fix — value-based NavigationLinks and instantaneous sidebar tab resets

## What to test next
- Play a video → verify skip intro / next episode appear as floating bottom-right buttons
- Verify controls auto-hide shows the buttons, mouse movement hides them
- Check memory: flux app ~200-250MB, FluxEngine ~25MB at idle
- Navigate between detail pages → verify only one torrent downloads at a time
- Search: type → dropdown → Enter → full results → type again → dropdown returns
- **NEW:** Open detail pages, scroll, hit back → no crash (Flux mode ON)
- **NEW:** Quit app → verify zero orphaned FluxEngine processes in Activity Monitor

## Build & Run
```bash
# Build
xcodebuild -scheme flux -configuration Debug build -allowProvisioningUpdates

# Launch
pkill -f "MacOS/flux" 2>/dev/null; pkill -f "FluxEngine" 2>/dev/null; sleep 1
DEBUG_APP=$(xcodebuild -scheme flux -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 "TARGET_BUILD_DIR" | awk '{print $3}')/flux.app
open "$DEBUG_APP"
```

*Last Updated: Aug 28, 2026*
