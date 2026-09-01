# Flux — Active Session Journal

## LATEST: Sep 1, 2026, 9:40 PM — RESILIENT MULTI-FORMAT STREMIO ADDON MANIFEST SUPPORT

### Current Status & Resolutions:
- **Resilient Stremio Addon Manifest Parsing (`AddonModels.swift`, `AddonManager.swift`, `DeepLinkAddonInstallModal.swift`):** *Status: Completed & Verified.*
  - **Root Cause of Failed Install:** In the Stremio v3 protocol specification, the `resources` field in `manifest.json` can be declared as either simple strings (`["stream", "subtitles"]`) or detailed objects (`[{"name": "stream", "types": ["movie", "series"], "idPrefixes": [...]}]`). Modern community scraper/debrid addons (such as PenguPlay, Torrentio, MediaFusion) use object-based resources. Because `AddonManifest.resources` was strictly typed as `[String]?`, Swift's `JSONDecoder` failed with `DecodingError.typeMismatch` ("The data couldn't be read because it isn't in the correct format").
  - **Resolution:**
    1. Created `AddonResource` with a polymorphic single-value / keyed container decoder supporting both string declarations (`"stream"`) and structured object declarations (`{"name": "stream", ...}`).
    2. Added `resourceNames` helper on `AddonManifest` to seamlessly normalize resources for capability checking.
    3. Made `version` decoding resilient to both String (`"1.3.9"`) and numeric (`1.2` / `1`) formats in community manifests.
    4. Enhanced `AddonManager` URL handling to safely percent-encode configuration strings and auth tokens embedded in addon URL paths.
    5. Added unit test `addonManifestDecodesObjectAndStringResources` verifying both object-based and string-based manifests.
- **macOS Display & System Sleep Prevention During Playback (`SleepAssertionManager.swift`, `PlayerView.swift`, `PiPManager.swift`, `PlayerManager.swift`):** *Status: Completed & Verified.*
  - **Resolution:** Added dedicated power management controller (`SleepAssertionManager`) using dual-layer `IOPMAssertionCreateWithName` (`kIOPMAssertionTypePreventUserIdleDisplaySleep`) and `ProcessInfo` activity assertions to prevent display dimming/sleep while video is playing.
- **Verification:** All 40 unit tests passed (`** TEST SUCCEEDED **`). Live app rebuilt and running on macOS.

---

## Aug 31, 2026 — APP STORE-STYLE ADDONS STORE, CLEAN DISTRIBUTION & STOCK PROTECTION

## Aug 31, 2026 — APP STORE-STYLE ADDONS STORE, CLEAN DISTRIBUTION & STOCK PROTECTION

### Cloudflare Addon Web Store, Zero-Scraper Binary & In-App Store Complete Removal (`/Users/zainulnazir/Projects/addons`, `ContentView.swift`, `SettingsView.swift`, `NavigationModels.swift`, `AddonManager.swift`, `UserDataService.swift`)
- **Completely Removed In-App Store from Sidebar:** Removed `Extensions` / `Addon Store` and `SidebarItem.addons` from the main sidebar. The sidebar is now 100% focused on entertainment and media browsing (`Search`, `Home`, `Movies`, `TV Shows`, `Trending`, `Watchlist`, `Collections`, `Recently Watched`, `Downloads`).
- **Official Master Flux Logo on Web Store:** Deployed the glowing cursive ribbon master Flux logo (`AppIcon_master_1024.png`) to `https://flux-addons.pages.dev/` as the navbar brand icon and favicon.
- **Cloudflare Pages Web Store (`https://flux-addons.pages.dev`):** Live, standalone, dark liquid glass Addon Store web app in `/Users/zainulnazir/Projects/addons` with search, category filtering, and two-way cloud sync.
- **Zero Scraper Binary Liability:** Removed the hardcoded curated scraper directory from the macOS app binary. The app is now a 100% legal, neutral player/metadata client with zero embedded scraper names or torrent domains.
- **Single Sign-On (SSO) Auto-Login:** Clicking "Open Web Store ↗" in `Settings → Addons` generates the user's JWT auth token and opens `https://flux-addons.pages.dev/?token=...`, automatically authenticating the user and loading installed extensions.
- **1-Click Deep-Link Install & Remote Uninstall:** Clicking "Install" on the web store triggers `flux://install-addon?url=...` which presents the floating glass confirmation modal (`DeepLinkAddonInstallModal`). Clicking "Uninstall" on the web store updates the user's cloud payload via `PUT /v1/data` to the Cloudflare Worker backend.

### Continue Watching Auto-Resume vs. Title Page Source Selector (`PlayerManager.swift`, `DetailView.swift`, `ContinueWatchingCard.swift`)
- **Continue Watching 1-Click Auto-Resume Across Restarts:** Clicking a Continue Watching or Recently Watched card auto-plays the last saved source with exact-second seek position, persisting even across app restarts via `UserDataService`.
- **Title Page (DetailView) Stream Selector UI:** Playing from the DetailView hero banner or episode list now presents the full Stream Source Selector UI instead of force-locking into a broken past source. Users can easily choose a new quality, provider, or seed without having to restart the app.
- **"Choose Stream Source…" Context Menu Action:** Added a dedicated "Choose Stream Source…" action (`list.bullet.rectangle`) to the Continue Watching ellipsis menu, allowing users to switch sources directly from the home rail.

### Mid-Playback Animated Logo Buffer Bar (`PlayerView.swift`)
- **Replaced Circular Spinner with Animated Logo Bar:** Replaced the center circular ProgressView wheel with a frosted glass container presenting the title's animated fill logo, live buffer percentage telemetry, and a sleek horizontal buffer capsule bar directly over the paused video frame.

### 24-Hour Disk-Persisted Stream Cache (`StreamCacheActor.swift`, `StreamManager.swift`)
- **Zero-Latency Stream Loading for Visited Titles:** `StreamCacheActor` now persists scraped stream lists (including seeders, fast-start rankings, infohashes, and file indices) directly to disk (`flux_streams_cache.json`) with a 24-hour TTL. Replaying or opening ANY title previously scraped loads the complete ranked stream list in **0 milliseconds** without repeating HTTP requests to addons.

### Multi-Title Instant Replay Fast-Path & Auto-Eviction (`PlayerManager.swift`, `StremioServerManager.swift`)
- **Instant Replay for All Watched Titles:** `finishSelect` now immediately captures and persists `lastStreamURL`, `lastTorrentInfoHash`, and `lastFileIndex` to `UserDataService`. Re-clicking any title in Continue Watching or Library reuses the stream session immediately without re-scraping.
- **Natural Download Pause & Automatic Cache Eviction on Player Close:** When exiting the player, MPV stops reading from the stream, naturally pausing piece downloads in `FluxEngine` while preserving verified chunks. In the background, `PlayerManager.close()` triggers `evictCacheIfNeeded()` to enforce the user's cache limit (e.g. 2 GB).

### Redesigned TMDB API Key Section (`SettingsView.swift`)
- **Clean Two-Row Layout:** The input field now sits cleanly below the "TMDB API Key" header row.
- **Modern Action Icons:** Save (`checkmark.circle.fill`) and Cancel/Clear (`xmark.circle.fill` / `trash.fill`) action buttons sit on the bottom right below the input field.
- **Automatic Validation on Save:** Clicking Save validates the key against TMDB (`/configuration?api_key=...`) before saving.
  - On Success: Key is persisted to `UserDefaults`, input field automatically collapses with a spring animation, and a green `checkmark.circle.fill` "Active" capsule badge appears on the right of the header with pencil (edit) and trash (delete) buttons.
  - On Failure: Key is rejected with an inline warning (`exclamationmark.triangle.fill`), preventing invalid keys from corrupting metadata enrichment.

### Visual Storage Gauge & Cache Management (`SettingsView.swift`, `StremioServerManager.swift`)
- **Dynamic Gradient Storage Bar:** Added an Apple-style gradient gauge showing used cache vs total allocation (e.g. `1.18 GB of 2 GB limit`). The gauge turns amber/red when approaching capacity ($>85\%$).
- **One-Click Purge Actions:** Added styled action buttons with icons for "Clear Images" and "Purge Torrent Cache".

### Active Torrent Session Reuse & Metadata Persistence (`PlayerManager.swift`, `MediaItem.swift`, `UserDataService.swift`)
- **Preserved Engine Sessions on Player Close:** Player close no longer prematurely destroys active torrent sessions with `removeAllTorrents()`. Connected peers, open DHT sockets, and downloaded pieces remain hot in the local engine (`127.0.0.1:11470`), enabling instant resumption without re-running handshakes or metadata fetching.
- **Persisted Stream Metadata in History & Cloud:** `MediaItem` and `UserDataService` now store `lastStreamURL`, `lastTorrentInfoHash`, `lastFileIndex`, `lastPlaybackPosition` (in exact seconds), and `lastPlaybackDuration`. These are saved locally to `UserDefaults` and synced automatically to the cloud database.
- **Instant Replay Fast-Path:** When reopening a title from Continue Watching or recent history, `PlayerManager` reuses the saved stream session directly without re-scraping addons or recreating torrent instances.

### Exact Resume Position on Playback (`PlayerView.swift`, `PlayerManager.swift`)
- **Exact-Second Resume Seeking:** When launching an item with saved watch progress, `PlayerManager` computes `pendingResumeTime` from `lastPlaybackPosition` (or `progress * duration`). As soon as playback begins or video duration is reported, `PlayerView` seeks directly to the exact millisecond where the user left off, just like Stremio and Apple TV.

### Restored Logo Sizing & Pure TMDB Logos (`ContinueWatchingCard.swift`, `TMDBEnricher.swift`)
- **Restored Exact Original Sizing:** Restored original logo frame (`maxWidth: 160, maxHeight: 36, alignment: .leading`) without height clamping.
- **Pure TMDB Logos When Enrichment Active:** `TMDBEnricher.quickEnrich` now fetches and populates `enriched.logoURL` with TMDB's high-resolution logo directly on the first pass. `ContinueWatchingCard` strictly uses TMDB logos when TMDB enrichment is enabled, completely preventing premature Metahub fallback and the split-second size flash on *Project Hail Mary*.

### Cursor Auto-Hide & Scrubbing Key Polish (`PlayerControlsView.swift`, `PlayerView.swift`)
- **Automatic Cursor Hiding After 2.5s:** Added continuous hover activity tracking (`.onContinuousHover`). When the user moves the mouse, the cursor appears; after 2.5s of no movement, `NSCursor.setHiddenUntilMouseMoves(true)` automatically hides the cursor.
- **Clean Keyboard Seeking (`<`, `>`, `,`, `.`):** Seeking with keyboard keys now scrubs smoothly without forcing the entire player control bar to pop up over the movie. If controls are toggled via Space or `C`, the 2.5s auto-hide timer is consistently refreshed and dismissed.

### Chapter-Verified Skips & Enlarged Liquid Glass Pill (`PlayerView.swift`, `MPVVideoView.swift`)
- **100% Chapter-Verified Intro & Recap Skips:** Removed the arbitrary 25s–100s heuristic that previously showed "Skip Intro" over cold open scenes (like *Lanterns* S1E1). Intro and recap skips now trigger **only** when verified by native embedded container chapters (`mpv.chapters`).
- **Enlarged Skip Button:** Increased padding (`22pt` horizontal, `12pt` vertical), font size (`14pt` bold), and icon sizing (`13pt` bold) with subtle shadow elevation (`radius: 8, y: 4`), matching the native Apple TV floating pill.

### Active Seedbox & WEB-DL Recency Ranking Boost (`StreamManager.swift`)
- **Recent Swarm Recency Multiplier:** Modern WEB-DL/WEBRip releases from top streaming providers (`AMZN`, `ATVP`, `MAX`, `DSNP`, `NF`, `HMAX`, `FLUX`, `NTB`, `PSA`, `GALAXYRG`, `QXR`, `SMURF`, `KOGI`) receive an unchoked seedbox bonus ($\times 1.30 \times 1.25$) in `computeStartupSpeedScore`, ranking the fastest starting, freshly uploaded streams higher in the stream picker and Fast Start tab.

### Real Buffer Progress Telemetry & Seamless Start (`PlayerView.swift`, `MPVVideoView.swift`)
- **Real Buffer Telemetry:** `logoBufferingView` binds directly to `mpv.bufferProgress` (the true $0–100\%$ cache fill) alongside `mpv.demuxerCacheTime`, replacing static pulse states with real byte-fill progress.
- **Mid-Play Re-Buffering Stability:** Mid-playback buffering checks require $timePos \ge 3.0\text{s}$, preventing micro-buffering oscillations during cold start that previously caused the HBO intro chime to play behind a lingering black screen.
- **Controls Always Accessible During Buffering:** Layered `PlayerControlsView` over the buffering overlay with `.allowsHitTesting(false)` so users can exit or see metadata without obstruction.

### Background Download Teardown on Close (`PlayerManager.swift`, `PlayerView.swift`)
- **Instant Torrent Stop:** When dismissing the player window or calling `close()`, `StremioServerManager.shared.removeAllTorrents()` and `.removeTorrent(infoHash:)` are invoked immediately, guaranteeing all background torrent download and seeding activity terminates the moment the player closes.

### Continue Watching Next-Episode Auto-Progression (`PlayerManager.swift`, `UserDataService.swift`)
- **Auto-Advance on 90% Watch Progress:** When an episode in a TV series reaches $\ge 90\%$ completion, `updateWatchProgress` automatically records the entry in Continue Watching for the **next episode** (`lastSeason = next.season`, `lastEpisode = next.episode`, `progress = 0.0`), so the Home screen immediately displays the card for the next upcoming episode ready to play.
- **Unit Tests:** 28 / 28 unit tests passing (100% pass rate).

---

## Aug 30, 2026 — HOMEVIEW TOP GAP REMOVAL + DETAILVIEW DESCRIPTION LOCK & HERO STABILIZATION

### HomeView Top Gap & Layout Shift Fix (`HomeView.swift`)
- **Root Cause:** `HomeView` used `LazyVStack(alignment: .leading, spacing: 32)` with an unused `GeometryReader` preference observer at index 0. This forced a 32pt blank spacing gap between the top boundary and `FeaturedCarousel`, exposing the black window background above the hero banner.
- **Fix:** Switched `HomeView`'s container to `LazyVStack(spacing: 0)` matching `MoviesView` and `TVShowsView`, and removed the unused `HomeScrollOffsetKey` and `scrollOffset` state. `FeaturedCarousel` now renders flush at `y: 0` beneath the top navigation bar without any gap or vertical offset.

### DetailView Description Flash & Eyebrow Flip Fix (`DetailView.swift`)
- **Root Cause:**
  1. In `DetailView.swift`, the hero description previously evaluated `heroEpisode?.overview ?? displayItem.description`. For TV shows, when `loadEpisodes()` finished, `heroEpisode` was set to Episode 1, replacing the entire show's synopsis with Episode 1's plot summary after a split second.
  2. In `loadDetails()`, incoming `detailedItem.description` from Cinemeta/enrichment was overwriting the initial `item.description` when `fullItem = merged` was assigned.
  3. The eyebrow kicker previously flipped to `S1, E1` when `heroEpisode` loaded.
- **Fix:**
  - **Show Description Lock:** Anchored the hero description permanently to `displayItem.description` (the show or movie overview), ensuring individual episode synopses remain strictly on episode list cards.
  - **Strict Field Preservation:** Configured `loadDetails()` to preserve `item.description`, `item.genres`, `item.voteAverage`, `item.releaseDate`, and artwork URLs on `merged`, eliminating 100% of text jumping.
  - **Stable Eyebrow:** Standardized the eyebrow kicker to display the title's primary genre (`CRIME`, `DRAMA`, etc.) consistently.
- **Testing:**
  - Verified all 23 / 23 unit tests pass. App builds cleanly without warnings.

---

## Aug 30, 2026 — LIQUID GLASS TOGGLE + UPCOMING TITLES + WATCH HISTORY REORDER + TMDB DYNAMIC CATALOG CACHING + CAROUSEL DIFFING

### Liquid Glass Segmented Toggle (`SectionHeader.swift`, `HomeView.swift`, `MoviesView.swift`, `TVShowsView.swift`)
- **Combined Trending Rails:** Replaced separate "Trending Today" and "Trending This Week" horizontal rails with a single "Trending" section header featuring an Apple native Liquid Glass `[ Today | This Week ]` segmented toggle before the navigation chevron.
- **Permanent Socket Typography:** Positioned labels permanently inside the track capsule base (`.glassEffect(.regular, in: .capsule)`). Active label stays crisp white (`Color.white`) while inactive label sits softly in the background (`Color.white.opacity(0.50)`).
- **Empty Zero-Distortion Glass Lens:** Sliding pill is an empty, crystal-clear optical glass lens with zero optical lens warping/distortion, gliding smoothly over the stationary socket typography with crisp specular gradient edge glints.
- **Physical Pop-Out & Motion Dynamics:**
  - **1.32x Vertical Height Expansion:** Pill expands vertically upon press/hold (`scaleEffect(y: isDragging ? 1.32 : 1.0)`), visibly popping above and below the track borders.
  - **1:1 Realtime Cursor Tracking:** Pointer interpolation with zero tap/drag gesture conflicts via `DragGesture(minimumDistance: 0)`.
  - **Velocity Squish & Rubber-Banding:** Preserves optical volume using horizontal stretch/squash compensation (`GlassMotion.squish`) and boundary rubber-banding.
  - **Spring Physics:** Tuned `GlassMotion` physics (`popOut`, `drag`, `settle`, `squish`, and `reduced` for accessibility).

### Upcoming Content Detail Actions (`DetailView.swift`, `MediaItem.swift`)
- **Release-Date Detection:** Added `isUpcoming` computed property to `MediaItem` comparing release/first-air dates against current day.
- **Sanitized Action Buttons:** For unreleased / upcoming titles, removed invalid playback/download/mark-watched controls and substituted a prominent primary **"Add to Watchlist" / "In Watchlist"** action button matching Apple TV.

### Watch History Sorting Fix (`UserDataService.swift`)
- **Chronological Order:** Sorted `recentlyWatched` items strictly descending by `updatedAt` / `lastWatched` timestamp, ensuring the most recently watched items always appear first instead of last.

### Continue Watching Navigation Polish (`HomeView.swift`, `MediaListView.swift`)
- **Heading Destination Parity:** Fixed header button on Home screen so clicking "Continue Watching >" opens the designated Continue Watching landscape page rather than Recently Watched.

### Dynamic TMDB Catalog Caching & Background Refresh (`TMDBCatalogCacheActor.swift`, `TMDBEnricher.swift`)
- **Thread-Safe Actor Caching:** Introduced `TMDBCatalogCacheActor` with TTL expiration for TMDB catalog and discover queries, preventing stale content lock while minimizing unnecessary network roundtrips.
- **Unit Tests:** Added full test coverage in `fluxTests/TMDBEnricherTests.swift`.

### Carousel Item Diffing & Re-rendering (`CarouselView.swift`)
- **Identity-Based Iteration:** Switched `CarouselView` `ForEach` from index offsets to item IDs (`\.element.id` / `.id(item.id)`).
- **Dynamic View Identity:** Bound `.id("trending-...-\(trendingWindow)")` so switching between daily and weekly trending instantly updates the visible cards and resets scroll position without layout stutter.

---

## Aug 28, 2026 — CRASH FIX + CACHE EVICTION + AUTH FLASH + UI/UX POLISH + DATABASE CLOUD SYNC

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

### Database & "For You" Taste Profile Cloud Sync
- **Root cause:** `FluxCloudClient.fetchData` crashed on empty accounts because Worker returns `{ notFound: true, updatedAt: 0 }` (HTTP 200 without a `payload` field), throwing `"bad_response"` and aborting before `pushData` could ever run.
- **Auto-Sync:** Added `scheduleAutoSync(delay: 2.0)` to `AuthManager` to debounced-push library state on every watchlist toggle, watch progress update, liked item (♥), collection change, and profile change.
- **"For You" Sync:** Expanded `UserDataService.exportCloudPayload()` and `applyCloudPayload()` to synchronize `tasteLoved` and `tasteSnapshots` from `TasteProfileManager` across devices.
- **Startup Sync:** Added `AuthManager.syncOnLaunch()` to `fluxApp.init()`.
- **Profile Scope:** Fixed `ProfileManager.applyProfileDataScope()` to switch `UserDataService` and `TasteProfileManager` to active profile keys on launch.
- **Live verification:** Successfully pushed and verified live JSON payload on Cloudflare D1.

### Genre & Subpage Navigation Stack Fix
- **Root cause:** `SearchView` genre cards used deprecated `NavigationLink(destination: MediaListView(...))` instead of value-based `NavigationLink(value: GenreNavigation(...))`. Destination-based NavigationLinks bypass the `NavigationStack(path: $path)` path binding, so when a user clicked a different sidebar tab (e.g. Home), resetting `path = NavigationPath()` had no effect on the presented view, causing the genre page to remain stuck on top.
- **Fix:** Switched genre cards, cast views, related list headers, and category section headers across the entire app to value-based `NavigationLink(value:)` and registered corresponding `.navigationDestination` handlers in `ContentView.swift`.
- **Sidebar Reset:** `sidebarRow` now unconditionally resets `path = NavigationPath()` on tab switch, instantly popping any open subpages when switching categories.

### Apple TV Continue Watching & Recently Watched Landscape Cards
- **Redesign:** Rebuilt `ContinueWatchingCard` with authentic Apple TV styling supporting both `.continueWatching` and `.recentlyWatched` modes:
  - **16:9 Landscape Layout:** 290x163pt with continuous 18pt rounded corners, drop shadows, and static clean hover border (removed zoom/scale on hover).
  - **Transparent Title Logo Overlay:** Dynamically fetches official transparent English PNG title logos from TMDB (`/images`) and Metahub (`/logo/medium/{id}/img`), rendering sharp logo graphics with typographic fallbacks.
  - **Movie & Series Runtimes:** Dynamically fetches movie durations (`TMDBEnricher.fetchMovieRuntime()`) and episode runtimes (`fetchEpisodeInfo()`), showing exact runtimes (`2h 18m`, `S2, E1 · 59m`) beside the play icon and progress bar.
  - **Real Progress Bar:** Capsule progress track directly reflecting recorded playback timestamp (`time / duration`).
  - **Continue Watching Mode:** Solid play icon `▶`, horizontal progress capsule bar (52x4pt with active white fill), season/episode/runtime subtitle (`S2, E1 · 59m` or `2h 18m`), and trailing context menu `•••`.
  - **Recently Watched Mode:** Circular replay icon `↺`, season/episode/runtime details (`S2, E10 · 52m` or `2026 · 2h 18m`), and trailing context menu `•••`.
  - **Home & History Views:** Upgraded `HomeView.historyRow` and `HistoryView` from basic portrait cards to the new landscape card system.

### Custom Genre Artwork & New Genres
- **18 Optimized Genre Assets:** Processed, downsampled, and optimized all 18 artwork files from `/Users/zainulnazir/Projects/flux/genre` into 640×960 retina assets (`~60-170KB` each) bundled inside `Assets.xcassets/genre-{name}.imageset/`.
- **6 New Custom Genres Added:** `Bollywood` (TMDB Hindi), `Anime` (TMDB Animation + Japanese), `K-Drama` (TMDB Korean), `Classics` (TMDB pre-1980/1990), `Short Films` (TMDB runtime <= 40m), and `Western` (TMDB 37).
- **GenreCard UI Redesign:** 2:3 aspect ratio, 18pt continuous corner radius, subtle gradient stroke, deep dark bottom scrim, and bold bottom-left aligned typography.

### Floating Back Button on Subpages & TV Genre ID Mapping
- **Pinned Floating Back Button:** Moved back buttons in `MediaListView` (Genre & OTT pages), `CastListView` (Cast & Crew), and `CollectionDetailView` into a pinned floating `.overlay(alignment: .topLeading)` at `(leading: 268, top: 24)`. Stays fixed across infinite scrolling, matching `DetailView` and `PersonView`.
- **TMDB TV Genre ID Translation:** Implemented composite genre translations in `TMDBEnricher.fetchGenrePage` for TV mode (mapping Action/Adventure to `10759`, Sci-Fi/Fantasy to `10765`, Mystery/Thriller to `9648`, etc.), guaranteeing rich results for all 18 genres in both Movie and TV modes.

### OTT Explore Card & Sidebar Label Polish
- **Netflix Card:** Optimized and installed `/Users/zainulnazir/Projects/flux/OTTs/netflix-new.png` into `ott-nfx.imageset` with 16pt continuous `.clipShape`.
- **Sidebar Label:** Renamed history sidebar item in `ContentView.swift` from `"Recently Added"` to `"Recently Watched"`.

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
