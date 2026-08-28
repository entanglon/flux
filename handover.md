# Flux — Active Session Journal

## LATEST: Aug 28, 2026 — CRASH FIX + CACHE EVICTION + AUTH FLASH + UI/UX POLISH

### Warm-Core NSWindow Double-Release Crash Fix
- **Root cause:** `cancelDetailPrefetch()` called `hostWindow?.close()` which auto-releases the window (`isReleasedWhenClosed = true`), then `warmCore = nil` released it again via ARC → crash
- Only crashed with Flux mode ON (only path that creates a warm-core host window)
- Repro: open detail page → scroll → back button → crash
- **Fix 1:** `buildWarmCore()` — added `host.isReleasedWhenClosed = false` at creation
- **Fix 2:** `cancelDetailPrefetch()` — changed `close()` to `orderOut(nil)` (matches safe `discardWarmCore()`)
- Diagnosed via Zombie Objects + MallocScribble (`NSZombieEnabled=YES MallocScribble=YES`)
- Zombie log caught: `*** -[NSWindow release]: message sent to deallocated instance`

### FluxEngine Orphan Process Fix
- **Root cause:** `ensureRunning()` nil'd `self.process` and launched a new FluxEngine without killing the old one. `stopServer()` only killed the last tracked process.
- Result: 5 orphaned FluxEngine processes at 99% CPU each, surviving app close
- **Fix 1:** `ensureRunning()` — kills old process (terminate + delayed SIGKILL) before launching new one
- **Fix 2:** `stopServer()` — added `pkill -f FluxEngine` safety net after killing the tracked process
- App exit now reliably kills all FluxEngine processes

### TMDB Key Validation UI
- Settings → General now has a **Save Key** button (no more auto-save on typing)
- Validates key against TMDB API before saving — invalid keys never persisted
- Green checkmark + "Key verified and saved" on success
- Red X + "Key didn't work — hasn't been saved" on failure
- Editing the field resets the status indicator
- Default TMDB key provided as a fallback (pre-filled as placeholder)

### Login Screen Flash Fix
- **Root cause:** `AuthManager.init()` restored the saved auth token via `DispatchQueue.main.async`, so `isAuthenticated` was `false` on the first SwiftUI render → `AuthGateView` flashed for one frame before switching to `ContentView`
- **Fix:** Set `isAuthenticated`, `currentUser`, and `isGuestMode` synchronously in `init()` instead of dispatching — safe because `init()` runs on the main thread before `@StateObject` observation begins

### Torrent Cache Eviction Fix
- **Root cause:** `cacheUsage()` and `evictCacheIfNeeded()` scanned `appPath/stremio-cache/` which doesn't exist with FluxEngine — the Go engine stores `{infoHash}/` dirs directly under `appPath`. Cache limit was **never enforced** and Settings always showed "0 KB"
- **Fix 1:** `torrentCacheDir` auto-detects layout (legacy `stremio-cache/` vs FluxEngine direct)
- **Fix 2:** `isTorrentHashDir()` — only targets 40-char hex dirs, protects config files
- **Fix 3:** `diskSize(of:)` — uses `totalFileAllocatedSize` for sparse `.part` files (actual disk blocks, not logical/pre-allocated size)
- **Fix 4:** Eviction now skips the currently-active torrent

### UI/UX Performance & Animation Polish
- **Main-Thread Scrolling Jank Fix (`CachedImage.swift`):** `downsample` now runs asynchronously via detached background tasks (`Task.detached(priority: .userInitiated)`) instead of synchronously on `@MainActor`, preventing scroll stutter when decoding heavy 4K / retina posters.
- **Carousel Interaction Guard (`FeaturedCarousel.swift`):** Auto-scrolling timer now pauses while the user is actively hovering (`!isHovering`) to prevent abrupt slide changes while reading or clicking, and uses smooth `.easeInOut(duration: 0.5)` transitions.
- **Smooth Skeleton/Loading Crossfades:** Added `.transition(.opacity)` and animated state updates (`withAnimation`) to `HomeView`, `DetailView`, `SearchView`, `MoviesView`, `TVShowsView`, and `TrendingView` to eliminate abrupt layout snapping when skeletons resolve to content.

---

## Previous Sessions

### Player UI — Skip Intro & Next Episode (Apple TV style)
- Moved from floating overlays to **bottom-right floating capsules** (like Apple TV's "Skip Recap")
- Only visible when player controls auto-hide (after 3s of no mouse movement)
- Disappear when mouse moves and controls reappear
- Uses `ultraThinMaterial` glass effect for clean look
- `isControlsVisible` is a `@Binding` from PlayerView → PlayerControlsView

### Memory Fixes
- **FluxEngine**: `GOMEMLIMIT=500MB`, `GOGC=20` (GC at 20% growth), `STREMIO_MEM_LIMIT=500MB`
  - Was 890MB with GOGC=50 — now 25-30MB at idle
- **mpv demuxer buffer**: 100MB → 50MB (warm core + player)
- **mpv backward buffer**: 20MB → 10MB
- **Detail hero image**: maxDimension 4096 → 1920 (saves ~25MB per hero)
- **Image URLCache**: 128MB → 32MB memory, 1GB → 512MB disk
- **NSCache**: 200 count / 100MB → 80 count / 30MB

### Double Torrent Download Fix
- Added `activeTorrentHash` tracking to PlayerManager
- `play()`: calls `cancelDetailPrefetch()` + removes old torrent before new playback
- `attemptStream()`: removes old torrent before registering new source (prevents auto-fallback stacking)
- `close()`: removes active torrent to stop background downloads
- Prevents race conditions where prefetch fire-and-forget /create competes with play's /create

### Search Improvements
- **Dropdown suggestions**: show while typing, hidden after submit
- **Full results**: only trigger on Enter/submit
- **Typing after results**: resets back to suggestion mode
- **Search card art**: increased GlassCard maxDimension 800 → 1200 for Retina

### OTT Catalog
- Streaming Catalogs addon data is stale (third-party issue — addon expired Oct 2025)
- `sharpPosterURL` correctly upgrades Cinemeta `/poster/small/` → `/poster/large/`
- OTT items with tt-prefixed IDs get metahub posters

### Thumbnail System
- In-memory NSCache with limits (80 count, 30MB cost)
- URLCache for disk storage (32MB memory, 512MB disk)
- Previous disk-only attempt reverted (hash collision bug)

---

## Previous Sessions

### Memory Lifecycle + Prefetch Cancellation (Aug 27)
- `STREMIO_MEM_LIMIT=512MB` env var, `applicationWillTerminate` handler
- `removeTorrent`/`removeAllTorrents` methods, `stopServer()` cleanup
- `cancelDetailPrefetch()` with `DetailView.onDisappear`

### Hero Quality Fix (Aug 26)
- WebP embedded thumbnail bug fixed (`CreateThumbnailFromImageAlways`)
- Image cache button fixed

### OTT Rail + Quality Fixes (Aug 26)
- 9 platforms with branded logos, portrait cards, GlassCard hover
- Backdrops 4K, posters metahub large, cache eviction

### Go Engine Shipped (Aug 26)
- FluxEngine sidecar (stremio-server-go v0.12.1, 24MB binary)
- Client firewall, registration tracking, supervisor

### Advanced Loading / Prefetch (Aug 26)
- DetailPage prefetch: stream fetch + torrent prime + warm mpv core
- Instant playback on Play after prefetch

### PiP v2 (Aug 26)
- Cascade architecture, working controls, expand/close round-trip

### Streaming Backend Overhaul (Aug 24)
- Hydra → Stremio server.js + FluxEngine
- Fire-and-forget /create protocol

---

## Key Architecture

```
Flux.app (SwiftUI + mpv)
├── StremioServerManager — FluxEngine sidecar (Go binary)
│   ├── GOMEMLIMIT=500MB, GOGC=20
│   ├── STREMIO_MEM_LIMIT=500MB
│   └── STREMIO_TORRENT_IDLE_TIMEOUT=600
├── StreamManager — fans out to Torrentio, Comet, WebStreamrMBG
├── PlayerManager — session controller, prefetch, auto-fallback
│   ├── activeTorrentHash tracking (prevents double downloads)
│   ├── warm mpv core (prefetch) — isReleasedWhenClosed=false, orderOut cleanup
│   └── PiP handoff
├── CachedImage — disk-backed with in-memory NSCache
├── TMDBEnricher — IMDb→TMDB resolution, quickEnrich/fullEnrich
└── mpv (libmpv) — 50MB demuxer buffer, hwdec auto
```

## Build & Run
```bash
# Build
xcodebuild -scheme flux -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Launch
pkill -f "MacOS/flux" 2>/dev/null; pkill -f "FluxEngine" 2>/dev/null; sleep 1
DEBUG_APP=$(xcodebuild -scheme flux -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 "TARGET_BUILD_DIR" | awk '{print $3}')/flux.app
open "$DEBUG_APP"
```

## Key File Locations
- `flux/Services/PlayerManager.swift` — playback, prefetch, auto-fallback, torrent tracking
- `flux/Services/StremioServerManager.swift` — FluxEngine process, env vars, torrent CRUD
- `flux/Services/StremioService.swift` — catalog fetching, OTT addon, search
- `flux/Services/StreamManager.swift` — addon fan-out, stream caching
- `flux/Services/TMDBEnricher.swift` — TMDB enrichment, poster URL upgrade
- `flux/Views/PlayerView.swift` — player UI, floating skip intro/next episode
- `flux/Views/PlayerControlsView.swift` — controls bar, subtitle/audio popovers
- `flux/Views/DetailView.swift` — detail page, prefetch trigger
- `flux/Views/SearchView.swift` — search with dropdown suggestions
- `flux/Views/SettingsView.swift` — settings (TMDB key validation UI)
- `flux/Components/CachedImage.swift` — image loading + caching
- `flux/Components/GlassCard.swift` — card component with image loading

*Last Updated: Aug 28, 2026*
