# Flux — Active Session Journal

## LATEST: Aug 26, 2026 (latest) — HERO QUALITY FIX + CACHE BUTTON FIX
Commit 9182131. Two fixes:

### Hero image quality (WebP embedded thumbnail bug)
- Root cause: `kCGImageSourceCreateThumbnailFromImageIfAbsent` silently used the
  WebP's embedded thumbnail (160×90) instead of decoding the full image.
- Fix: switched to `kCGImageSourceCreateThumbnailFromImageAlways` which forces
  full decode. Hero now renders at 1920×1080 (source resolution for these titles).
- Added debug logging (`ImageDebugLog` writes to /tmp/flux_image_debug.log).
- Note: metahub `large` tier is not consistently 4K — some titles (Shawshank,
  Interstellar) are 1920×1080, others are 3840×2160.

### Clear Image Cache button
- Was clearing wrong directory + accidentally touching torrent-related caches.
- Now only clears: ImageSession URLCache, ImageInMemoryCache NSCache, FluxImageCache dirs.

---

## Aug 26, 2026 (latest) — OTT RAIL + QUALITY FIXES + CACHE EVICTION
Commit ac91bd8. All requested fixes shipped:

### OTT Explore rail
- 9 platforms with real branded logos (Netflix, Disney+, Prime Video, Apple TV+,
  HBO Max, Hulu, Peacock, Paramount+, Crunchyroll) in OTTs/ folder.
- OTTCard: portrait (2:3), full-bleed logo image, no gradient backdrop, no text labels.
- Hover matches GlassCard exactly (dark overlay, border highlight, shadow, no zoom).
- Catalog pages preserve platform's native popularity order (preserveOrder flag).
- Frame: 200pt wide, matches content card width in rails.

### Hero/poster quality
- Backdrops: stored at metahub large tier (3840×2160), CachedImage maxDimension 3840.
- Posters: metahub large (780×1170) by IMDb ID for all items (fixes JustWatch s332).
- Verified: Shawshank (tt0111161) and Interstellar (tt0816692) resolve 200 OK.

### Cache eviction
- Client-side `evictCacheIfNeeded()` — sorts dirs by modification date, deletes oldest.
- Runs at startup and when Settings cache size picker changes.
- Verified: 3.3 GB → 1.4 GB (under 2 GB limit).

### CastListView
- Now matches MediaListView structure: liquid glass back button, 44pt heavy title,
  same padding (268 left, 40 right/top/bottom), hidden nav bar and toolbar.

---

## Aug 26, 2026 (latest) — CLEAN RELEASE BUILD + BUNDLE AUDIT
Release build: **115MB** (Firebase SDK bundles added ~23MB over the 92MB
pre-auth build — expected). ZERO stray files in bundle after fixes:
- REMOVED from flux/ (would have bundled): .DS_Store, implementation_plan.md,
  Services/SecretsExample.txt (→ docs/), MPVKit-Swift/Scripts/*.sh
  (→ scripts/mpvkit-legacy/ — NOTE: directory-level membershipExceptions did
  NOT exclude these; only explicit file paths work reliably).
- Bundle now contains ONLY: Assets.car, AppIcon.icns, FluxEngine, plist,
  Firebase/gRPC/GoogleUtilities resource bundles. Verified by find sweep.
- Release app launched (PID varies) for account-creation testing.
- Root-level junk NOT in bundle (outside synced group): ContentView_Backup.swift,
  default.profraw, Flux.dmg, FluxImageCache/, ui.png etc. — cleanup optional.

---

## Aug 26, 2026 (latest) — FIREBASE AUTH HYBRID + FIRST-START GATE
Identity delegated to Firebase Auth (user created project "flux-streaming",
plist dropped at repo root → moved into flux/ for bundling).

### AuthManager rewritten onto FirebaseAuth
- signUp/signIn via Auth.auth(); errors mapped from AuthErrorCode (note: SDK
  uses AuthErrorCode(rawValue:) NOT AuthErrorCode.Code).
- Session persistence native to Firebase (no Keychain juggling);
  PasswordDeriver deleted; FluxCloudClient slimmed to fetchData/pushData
  (Bearer = fresh ID token via getIDToken()).
- Guest mode: continueAsGuest() persists UserDefaults "flux.authGuestMode";
  signOut clears it → identity gate reappears.
- GOTCHA: our Models/User.swift struct User now coexists with FirebaseAuth.User
  — same-module declaration shadows import ✓ but keep FirebaseAuth.User
  explicit where both appear. AuthErrorCode.Code doesn't exist in this SDK.

### First-start gate (Views/Auth/AuthGateView.swift)
Flow: needsGate (= backend configured && not authenticated && not guest) →
AuthGateView [Create Account / Sign In / Continue as Guest] → ProfileGateView
→ ContentView. Returning users w/ live Firebase session skip gate.
- AuthView gained startInSignUp param (+ Identifiable for sheet(item:)).
- fluxApp body chains gates; dev fallback skips gate when plist/backend absent.

### Worker v2 deployed (JWT verification)
- verifyIdToken(): JWKS cached 1h, RS256 via WebCrypto, aud/iss/exp/iat/sub
  checks against FIREBASE_PROJECT_ID var ("flux-streaming").
- Password/session routes DELETED; D1 keyed by Firebase UID; users table =
  upserted profile record only.
- Verified live: 401 no-auth, 401 garbage token, 404 unknown route.
- E2E WITH REAL TOKEN still blocked on: enable Email/Password provider in
  Firebase console (CONFIGURATION_NOT_FOUND from identitytoolkit).

---

## Aug 26, 2026 (latest) — BACKEND DEPLOYED + LIVE API VERIFIED ✅
Deployed via user's wrangler (logged in as haditbutt7@gmail.com):
- D1 database `flux` created (id 770ad44b-a383-4931-b6ea-7c4708190504, APAC)
- Schema applied; Worker live at **https://flux-backend.nemesys.workers.dev**
- FULL LIFECYCLE SMOKE TEST PASSED: signup → PUT data → GET data (exact
  payload round-trip) → stale push rejected (superseded:true) → me → re-login
  → logout invalidates session. Test user deleted afterwards.
- FluxCloudConfig.baseURL now points at the deployed URL (isConfigured=true).

### NOTE — auth architecture pivot pending
User approved hybrid: Firebase Auth ONLY for identity + Cloudflare for data.
Current deploy = pure-Cloudflare password auth (fully working). Next session:
swap Worker signup/login/logout+sessions table for Firebase ID-token
verification (JWKS RS256), re-key D1 rows by Firebase UID, swap AuthManager to
FirebaseAuth SDK (packages already linked), delete PasswordDeriver + Keychain
token juggling (Firebase persists its own). User must create Firebase project +
GoogleService-Info.plist first.

---

## Aug 26, 2026 (latest) — CLOUDFLARE ACCOUNTS + LIBRARY SYNC BUILT
Backend (backend/ folder, deploy with wrangler — see backend/README.md):
- Worker API: /v1/signup|login|logout|me + GET/PUT /v1/data. D1 schema:
  users, sessions, user_data (JSON blob), auth_attempts throttle.
- Password scheme: CLIENT derives PBKDF2-SHA256(pw, SHA256(email), 250k) via
  CommonCrypto and sends only the derived hex; server stores one cheap 10k
  round on top → raw passwords never leave device, Workers CPU limit safe.
- Sessions: random 32B tokens, only SHA-256 stored, 90-day expiry; login
  throttling 8 fails/15min per email+ip.
- PUT /v1/data rejects stale pushes (superseded:true when server newer).

Swift side:
- KeychainStore.swift (generic-password wrapper). FluxCloud.swift = config +
  client (+PasswordDeriver). AuthManager REWRITTEN from dummy to real network
  auth w/ Keychain session restore + pull-on-login/push-on-signout sync.
- UserDataService.exportCloudPayload()/applyCloudPayload() (whole-blob
  newer-wins merge v1) + hasLibraryContent.
- Settings→General account row: signed-in email + Sync Now + last-sync stamp;
  signed-out shows Sign In sheet (AuthView reused).
- CONFIG STEP REQUIRED: set deployed URL in FluxCloudConfig.baseURL or
  UserDefaults "cloudBaseURL" (isConfigured guards until then).

### USER DEPLOY STEPS
cd backend && wrangler login && wrangler d1 create flux (paste id into
wrangler.toml) && wrangler d1 execute flux --remote --file=schema.sql &&
wrangler deploy → paste URL into FluxCloud.swift default.

---

## Aug 26, 2026 — GO ENGINE SHIPPED + BULLETPROOFING LAYER 1
Consultant decision executed. App now runs the **FluxEngine sidecar**
(stremio-server-go v0.12.1, MIT, 24MB binary in flux/Engine/ → Resources) as
PRIMARY torrent engine. Node+server.js = automatic fallback. VERIFIED LIVE:
engine boots, binds 11470, uses Flux APP_PATH.

### What changed
- **Engine resolution** (`resolveEngine()`): bundled FluxEngine (explicit port
  assignment 11470→11474 — it does NOT self-increment, verified) → node+
  server.js (self-increments; HTTP_PORT hint set). server.js download no longer
  blocks startup when sidecar present.
- **Client firewall** (PlayerManager): `validInfoHash` — exactly-40-hex,
  non-zero, non-degenerate. torrentHash() returns nil otherwise;
  attemptStream() rejects malformed torrents via advancePast (manual-mode aware);
  getPlayableURL guards URL construction. Addon magnets = attacker-controlled
  input, validated at perimeter per consultant spec.
- **Registration tracking + invisible restarts**: trackCreate(infoHash,magnet,
  fileIdx) recorded at create time; ensureRunning() success-after-restart
  replays ALL active registrations fire-and-forget so mpv reconnects onto a
  live swarm without user action.
- **Supervisor**: exponential backoff relaunches (.25→5s), rolling-window
  crash cap (5 failures/60s → failed state, no CPU burn), killStaleEngines()
  at startup (pkill -f our exact paths only — never real Stremio).
- Sidecar exec-bit restored at runtime if resource-copy drops it.

### Engine facts learned (verified live)
- Go engine answers /heartbeat ✓ (port discovery unchanged)
- Does NOT self-increment on conflict → explicit HTTP_PORT assignment required
- Panic-on-zero-infohash lives in anacrolix/torrent lib (upstream); Swift
  firewall prevents it reaching the engine from OUR client; fork hardening =
  remaining workstream

### Fork TODO (flux-engine fork, next session)
- Clone M0Rf30/stremio-server-go → fix panicif.Zero inside engine (400 instead
  of fatal) → fast-resume persistence → localhost auth token → seeding policy
  (ratio/Low Power Mode) → DHT toggle + VPN kill switch → sparse-allocation
  check → async HTTP tuning for mpv parallel connections
- Ship gate: chaos matrix (fuzz 100k / kill -9 x500 / 24h soak) green

---

## Aug 26, 2026 — STREAMING ENGINE DECISION (consultant-reviewed)
Asked Claude + Qwen (+ Gemini via user) with identical neutral prompt.
VERDICT (2:1 + my analysis): **fork stremio-server-go → harden → supervised
sidecar. ONE path. No Node, no librqbit.**
- Unanimous: sidecar over embedded (crash isolation = req #1); librqbit
  unusable for playhead-priority streaming (kills Candidate B as-is).
- Deciding factor: anacrolix/torrent has years of production proof for
  seek-driven piece prioritization (Elementum/Kodi); Rust path = rewrite
  librqbit picker (months) OR drag libtorrent C++ through FFI (cancels Rust's
  safety advantage). Gemini's anti-Go args (cgo wall) don't apply to loopback-
  HTTP sidecar architecture; its unique gotchas adopted anyway.
- Bulletproofing spec adopted from consultants:
  - Swift supervisor: /stats.json heartbeat, exp-backoff restarts capped per
    rolling window, INVISIBLE restarts via cached session replay (/create +
    last Range)
  - Orphan prevention: --parent-pid flag or held-pipe EOF
  - Validate infohash(40-hex/base32 non-zero)+fileIdx at Swift firewall AND
    inside fork (kills the observed panicif.Zero crash class)
  - Ephemeral port (never hardcode 11470); idle-torrent reaper (10-15min);
    memory ceiling w/ proactive idle recycle
  - Sparse disk allocation (APFS stall gotcha); async multi-threaded HTTP
    (mpv opens parallel Range connections)
  - Seeding policy (ratio limits/Low Power Mode), DHT/PEX toggles + VPN-drop
    kill switch = expected user controls
- SHIP GATE: fuzz 100k malformed reqs = 0 crashes; kill -9 x500 mid-playback =
  0 host crashes + bounded rebuffer; 24h soak flat RSS <10% growth; sleep/wake
  + network flaps self-recover.
- Signing note: sidecar binary needs own Developer ID sig matching app +
  hardened-runtime entitlements (packaging-time task).
- Rust not dead FOREVER: HTTP contract keeps engines swappable; revisit
  in-process Rust embed (stremio-native style) once librqbit matures.

### Consultant prompt pattern stored in handover.md (AI Consultant Workflow).

---

## Aug 26, 2026 (latest) — Release verification + Node self-provisioning
RELEASE: builds clean at 92MB (Debug 100MB). USER VERIFIED RELEASE PLAYBACK ✅.
Direct distribution planned (no App Store).

### Node.js runtime self-provisioning (Services/StremioServerManager.swift)
Stremio desktop bundles its JS runtime; our end users can't be assumed to have
Node. New resolution order in launchAndDiscoverPort → resolveNodePath():
1. System node (homebrew/nvm v20/22/24 candidates)
2. Previously-downloaded runtime at ~/Library/Application Support/Flux/runtime/node
3. One-time download of official nodejs.org dist (v22.14.0 darwin arm64/x64,
   ~47MB tar.gz) → URLSession download → /usr/bin/tar extract ONLY bin/node
   (--strip-components=2) → chmod 755 → smoke-test `node -v` before use.
Failure surfaces as existing "Streaming server unavailable" path. Verified
dist URL + extraction + execution standalone in /tmp before wiring.

### Accounts — DECISION PENDING (options researched)
- AuthManager is currently a LOCAL DUMMY (simulated sign-in, no backend).
- Firebase SDK packages are ALREADY LINKED in the project (GoogleUtilities,
  nanopb, leveldb, RecaptchaInterop seen compiling) — fastest to wire.
- Options: Firebase Spark free / Supabase free (500MB PG, supabase-swift) /
  CloudKit ($0 + native, needs $99 dev acct which notarization needs anyway,
  zero login UI via iCloud identity) / PocketBase self-host.
- RECOMMENDATION: CloudKit if goal = sync profiles/watchlist/collections across
  the user's own Macs with zero friction; Supabase/Firebase if real email
  accounts + future iOS/web.

### Release readiness checklist
✅ Release build size+compile ✅ playback (user) ✅ Node dependency solved
⬜ Developer ID signing + hardened runtime + notarization (needs $99 acct)
⬜ Account backend decision + wiring (or strip account UI for local-only v1)
⬜ Minor: For You live refresh after ♥

---

## Aug 26, 2026 (latest) — App Icon Switcher REVERTED (user call)
In-app icon switching attempted (setAlternateIconName is iOS-only; tried
resource-swap approach) then icon normalization to full-bleed for Tahoe's
auto-border — result rendered as an unmasked BOX. USER: "just go back".
REVERTED: original pre-shaped AppIcon.iconset PNGs restored into the asset
catalog, flux/Icons/ + Info.plist + pbxproj INFOPLIST_FILE lines deleted,
AppIconPicker/AppIconManager/AppDelegate hook removed from code.
LESSON: macOS 26 does not auto-mask arbitrary full-bleed icns in dev builds
the way I assumed; pre-shaped Big-Sur-style art is what this app should use.
Keep flux-icons/*.png around as future alternate-icon SOURCE art only.

### Still in place from earlier today
Hero/poster fixes (HeroBackdrop, GhostHero 680pt, GlassCard decode 800),
library page unification, Collections, prefetch advanced loading, PiP v2.

---

## Aug 26, 2026 (latest) — App Icon Switcher + Hero/Poster Fixes
Builds clean, relaunched.

### App Icon switcher (Settings → General)
- macOS has NO setAlternateIconName (iOS-only API!) — persistent switch for
  non-sandboxed builds = overwrite Contents/Resources/AppIcon.icns with chosen
  .icns + NSApp.applicationIconImage for live feedback. Choice saved to
  UserDefaults("appIconChoice"); AppDelegate.applicationDidFinishLaunching re-
  applies it every launch (rebuilds regenerate the asset-catalog icns).
- Icons: flux-icons/*.png (1024² alpha) → sips 10-size iconsets → iconutil
  .icns (~2.5MB each) in flux/Icons/ (fs-synced folder auto-bundles them).
  FluxDefault.icns = stashed pristine asset-catalog output (restore path).
- Settings → General → App Icon section: 5 previews (Flux/Cascade/Nature/
  Play/Quantum), white ring on active, click swaps instantly (Dock updates
  live; Finder/Dock file icon fully consistent after relaunch).
- Added flux/Info.plist (CFBundleIcons/CFBundleAlternateIcons declared —
  future-proofing) + INFOPLIST_FILE=flux/Info.plist merged into BOTH app-target
  configs via python pbxproj edit alongside GENERATE_INFOPLIST_FILE=YES.

### Hero & poster fixes
- NEW Components/HeroBackdrop.swift — shared banner builder: full-width artwork
  (one natural crop; old HStack double-crop over-zoomed heroes) + TRUE mirrored
  reflection aligned to seam via scaleEffect(x:-1)+offset(2·sidebar−W) then
  masked to sidebar strip. Used by FeaturedCarousel AND DetailView.
- GhostHero now fixed height 680 matching FeaturedCarousel's real frame (was
  fluid 16:9 → size jump on load). GhostViews.swift.
- Poster sharpness: GlassCard decodes at maxDimension 800 (was default 300 →
  upscaled blur on Retina); landscape-fallback poster copies too; collection
  card stacks 600.

---

## Aug 26, 2026 (latest) — ADVANCED LOADING / Detail-Page Prefetch SHIPPED
Builds clean, relaunched — awaiting runtime test.

### What shipped (both user asks)
1. **Non-Flux**: opening a DetailView fetches all sources in the background
   (populates StreamManager cache) → stream picker appears INSTANTLY on Play.
2. **Flux Mode**: page open → fetch → race best source → PRIME it (torrent
   registered on server fire-and-forget / HTTP ranged GET warms proxy+CDN) →
   build WARM MPV CORE holding the stream PAUSED while buffering. Hitting Play
   adopts that core → playback starts instantly, zero spinner.

### Architecture (Services/PlayerManager.swift)
- `startDetailPrefetch(item:season:episode:)` — DetailView .task after
  loadDetails + on season-dropdown change (S{n}E1). Deduped per key; skipped
  while any session active (currentItem != nil or PiP).
- `runPrefetch`: fetchStreamsRealtime → flux-only: raceBestStream → prime →
  buildWarmCore(key,url). Subtitles fetched in parallel and stashed.
- Warm core = MPVController+MPVViewController built OUTSIDE SwiftUI, parked in
  an invisible 160×90 host window (alpha 0.01, level -1, screen corner).
  ⚠️ HOST WINDOW IS MANDATORY: this pipeline creates the mpv render context
  lazily inside CAOpenGLLayer.draw() — a fully detached layer NEVER composites,
  draw never fires, mpvGL stays nil, loadfile defers forever. Invisible-but-
  onscreen window keeps the GL context alive so buffering proceeds.
- Hold pattern: pause() BEFORE play(url:) → loads paused, demuxer cache fills.
- `acquireSessionController()` — PlayerView.init swaps @StateObject for
  @ObservedObject acquiring warm core when key AND resolved URL match
  (⚠️ Instant-Replay uses an older URL — URL match prevents adopting a core
  that buffers a DIFFERENT source than currentStreamURL). Else fresh controller.
- PlayerView.onAppear: `mpv.hasLoadedMedia` (new flag set in play(url:), cleared
  in stop()) → resume hold instead of second loadfile (double-load would
  restart buffering at zero).
- fetchAndRace fast-path (flux only): prefetchedKey==key & <10min old &
  prefetchedStream exists → finishSelect instantly; availableStreams filled from
  StreamManager cache for fallback picker; stashed subtitles applied.
- TTL: warm core discarded after 5 min, on supersede, on close(), or on mismatch.
- Manual-mode contract preserved: non-flux NEVER auto-selects; fast-path is
  flux-only (auto mode).

### TODO verify (runtime)
- Open movie page ~10s → Play → instant start (log: "⚡ Prefetch HIT" +
  "⚡ Adopting warm mpv core")
- Flux OFF: Play → picker shows immediately with sources already listed
- Season dropdown switch re-primes; PiP still works from adopted session;
  no RAM growth beyond one held core

---

## Aug 26, 2026 (latest) — Library Pages Unified (user-directed)
USER DIRECTIVE: library pages must follow ONE clean scheme — NO fancy
multicolored icons. All four pages now share the same scaffold.

### What changed
- NEW `Components/LibraryViews.swift`: `LibraryScheme` (shared paddings) +
  `LibraryEmptyState` — THE single empty-state component (monochrome icon in
  clear glass circle, 22pt title, 14pt message, optional glass-capsule action).
- WatchlistView / HistoryView / CollectionsView(hub+detail) / DownloadsView all
  render LibraryEmptyState; every gradient icon removed (cyan→blue bookmark,
  purple→blue clock, purple→indigo stacks, teal→cyan download/checkmark).
- DownloadsView brought onto standard page scaffold: was missing
  navigationBarBackButtonHidden + toolbarVisibility(.hidden), had stray
  .ignoresSafeArea(.top), missing leading padding + wrong bottom padding.
  Section headers .title3 → 20pt bold. Progress fill cyan → white 0.85;
  completed tile gradient → neutral white 0.08 w/ plain checkmark.
- Collections: poster-stack backdrop purple→indigo gradient → white 0.06;
  popover checkmark purple → white; member-row tint purple → white 0.07;
  create-plus purple → white. Semantic red kept ONLY on destructive trash.

### Library page contract (keep this for future pages)
Header: 44 heavy white + count badge (11 bold tracking 1.5, clear glass capsule)
at .padding(.top, 48). Content: leading 268 / trailing 40 / bottom 60,
ScrollView .background(Color.clear), navigationBarBackButtonHidden(true),
toolbarVisibility(.hidden). Empty state = LibraryEmptyState. Monochrome only;
red reserved for destructive actions.

---

## Aug 26, 2026 (later) — Collections (custom user lists) SHIPPED
Builds clean, app relaunched — awaiting runtime test.

### What shipped
- **Model**: `UserCollection` (Models/UserCollection.swift) — id/name/createdAt/
  items. Items stored as MediaItem dicts (SAME shape as watchlist/history) so
  grids render offline with artwork; persisted via JSONSerialization blob inside
  one UserDefaults array per profile.
- **Storage**: UserDataService owns it (`profile.{uuid}.collections` key, scoped
  by switchProfile like watchlist/history). API: create/rename/delete,
  toggleCollectionMembership, removeFromCollection, isInCollection,
  collectionIDs(containing:).
- **Sidebar**: new `SidebarItem.collections` case → "Collections" row in Library
  section (rectangle.stack icon, runtime-validated). Hub page via ContentView
  switch + pushable `CollectionNavigation` destination.
- **CollectionsView** (hub): Apple-TV header + count badge, "+ New List" glass
  button (alert w/ TextField), dashed New tile leading the grid, empty-state
  glass card. Cards = fanned poster stack (up to 3 members, CachedImage w/
  content closure — NOTE: CachedImage REQUIRES @ViewBuilder content closure, no
  plain init), name/count caption, hover pencil/trash actions + contextMenu,
  rename/delete alerts (delete keeps titles, only removes list).
- **CollectionDetailView**: pushed grid of members (GlassCard portrait,
  NavigationLink→Detail works via existing MediaItem destination), X-badge on
  hover to remove items, rename/delete in header, member-empty state.
- **DetailView**: new glass circle button (rectangle.stack.badge.plus,
  validated) next to Love → popover listing collections with live checkmarks +
  inline "New list name" field that creates AND adds in one step.

### Gotchas this round
- CachedImage(url:) alone doesn't compile — needs trailing content closure
  (phase.image pattern, see GlassCard).
- Nested Button inside NavigationLink label intercepts its own tap (hover
  actions don't navigate) — verify at runtime.

### TODO verify (runtime)
- Create/rename/delete lists from hub + detail; per-profile isolation
- Poster stacks render; add/remove via DetailView popover checkmarks
- Hover trash/pencil on cards navigate correctly (should NOT navigate)

### REMAINING
- Account system decision (Firebase vs alternatives) + login/signup + guests
- Cascade personal Telegram debrid (future plan, personal-scale only)
- Release build verification (size + playback)

---

## Aug 26, 2026 — PiP v2 (Cascade architecture) VERIFIED BY USER ✅
"Perfect." Entry seamless, controls work, expand/close round-trip good.
Next up: Collections (custom user lists).
Builds clean, app relaunched. v1 worked for ENTRY but controls were dead + user
wanted Cascade parity ("pip limited to that window").

### Why v1's controls were dead (lesson)
Borderless NSPanel with canBecomeKey=false → never becomes key window →
tracking-area enter/exit NEVER delivered → hover chrome never appeared →
"controls aren't working". Cascade uses [.titled, .closable,
.fullSizeContentView, .nonactivatingPanel] + makeKeyAndOrderFront → key-capable,
native traffic lights, working hover.

### v2 = faithful port of Cascade Features/PictureInPictureWindow.swift
CONTRACT: entering PiP ADOPTS the mpv core and CLOSES the player window — the
panel is where playback lives. No zombie windows.
- PiPManager RETAINS layer (MPVLayerView) + MPVViewController + MPVController
  (PlayerView's @StateObject dies with the window; weak refs would dangle).
- Teardown hazard #1: MPVVideoView.dismantleNSViewController skips cleanup while
  PiPManager.isHosting(layer) (Cascade-exact pattern).
- Teardown hazard #2: PlayerView.onDisappear guards on isHandingOffCore so the
  handoff close neither saves progress nor stops mpv.
- Panel: titled+closable+fullSizeContentView+nonactivating, hidden transparent
  titlebar (traffic lights work), .floating, canJoinAllSpaces+fullScreenAuxiliary,
  movable by background, aspect-sized (~400w cap 300h), remembers last position.
- Mini chrome (SwiftUI in NSHostingView pinned bottom, hover via tracking area):
  play/pause · live title · expand · 2pt progress line. Overlay binds to
  @Published miniIsPlaying/miniProgress/miniTitle mirrored from the controller.
- Duties taken over from PlayerView while floating:
  - mpv.onPlaybackError → PlayerManager.tryNextStream() (auto-fallback works)
  - $currentStreamURL.dropFirst() → play new URL in same core (⚠️ dropFirst is
    CRITICAL — Combine replays current value; without it entering PiP restarts
    playback at 0:00) + refresh miniTitle
  - 0.5s timer: preload >0.9, auto-play-next at ≤1s remaining (respects
    Settings toggle); playNextEpisode passes isAutoAdvance:true so it skips
    intercept and keeps floating
- Exit paths:
  - Expand button / re-opening same title → full stop (layer.cleanup()) +
    pendingResumeTime armed → PlayerWindowRouter.openPlayer(itemID) reopens
    player window → PlayerView seek-once onChange(timePos>0.3) resumes exactly
  - X / traffic light → save progress → PlayerManager.close() → full stop
  - User plays a DIFFERENT title → play() top calls
    interceptPlaybackRequest(): saves progress + tears down before refetch
- PlayerWindowRouter.openPlayer captured from ContentView environment
  (openWindow is env-only; static closure bridges AppKit→SwiftUI).

### GOTCHAS hit (do not re-learn these)
- NSColor has NO .opacity (AppKit) → withAlphaComponent. NSView has NO
  insertSubview (UIKit). mouseEntered(_:) → mouseEntered(with:) newer SDK.
- Subclassing NSView.init(frame:) EXACTLY needs `override` (different signature
  doesn't).
- Borderless panels break ALL input routing (see lesson above).
- Combine @Published replays current value on subscribe → dropFirst() when the
  side effect must only fire on CHANGES.

### TODO verify (runtime)
- Enter PiP: video continues seamlessly, NO restart at 0:00 (dropFirst check)
- Hover shows strip; play/pause + expand + traffic-light close all work
- Expand resumes at exact position; X saves progress and stops
- Auto-next episode keeps floating; dead source falls through headlessly
- Playing another title from browse UI tears down panel cleanly

### REMAINING
- Collections (custom user lists)
- Account system decision (Firebase vs alternatives) + login/signup + guests
- Cascade personal Telegram debrid (future plan, personal-scale only)
- Release build verification (size + playback)

---

## Aug 25, 2026 (session 3) — Feature Wave: 7 features shipped
Committed 7a83d76. Shipped: OpenSubtitles integration (addon + player picker),
auto-play next episode (10s countdown + Cancel) & Skip Intro (first 90s),
real Downloads (stream-to-file, progress, offline playback), Person pages
(cast circles -> hero page -> filmography -> detail), season dropdown (root-overlay
pattern after 4 failed approaches — see notes), Meteor+Stremify addons (live-verified),
Flux Mode source-filter support, language-aware health ranking, TV genre toggle,
search autocomplete, NEW EPISODE badges, per-profile playback settings, hydra fully
removed, app icon flux-cascade. App size: 100MB Debug.

### KEY LESSONS (do not re-learn these)
- Value-based NavigationLinks don't resolve inside destination-pushed views ->
  use NavigationLink(destination:) for PersonView filmography cards
- PreferenceKey values don't propagate out of pushed NavigationStack views on
  macOS -> write frames directly to a shared controller via GeometryReader
  onChange (season dropdown anchor)
- Native Menu/popover are modal (block scrolling); ZStack panels push layout;
  overlay-on-button loses z-order to later siblings. Final season dropdown =
  inline expanding panel (pushes rail down — user accepted) after trying
  root-overlay pattern (works but user preferred inline)
- SF Symbols: validate at runtime (ghost.fill/skull.fill don't exist)
- Stremify streams need referer from behaviorHints.proxyHeaders (auto-injected)
- WebStreamrMBG + Meteor verified working (user's Stremio setup was right)
- OpenSubtitles v3 addon: https://v3-opensubtitles.strem.io (subtitles resource)

### REMAINING
- PiP / mini floating player window (medium effort — custom mini window, mpv
  has no native PiP; PIP button in player is a stub)
- Collections (custom user lists)
- Account system decision (Firebase vs alternatives) + login/signup + guests
- Cascade personal Telegram debrid (future plan, personal-scale only — see below)
- Release build verification (size + playback)

---


> Check this file first when starting a session. `handover.md` is long-term memory; this is the working state.

## Session: Aug 25, 2026 — Profiles, mpv 0.41, Ghost Loading, App Size

### Outcome: playback verified on mpv 0.41 ✅ · app 1.6GB → 100MB ✅ · local profiles shipped ✅

### Local multi-profile system (Netflix-style, local-only)
- `ProfileManager` + `UserProfile` + `AvatarStyle` (Models/UserProfile.swift).
- Gate: fluxApp shows `ProfileGateView` when `currentProfile == nil` — selection
  ("Who's Watching?") / creation (glass panel, name + avatar strip) / **Manage Profiles**
  (pencil=edit pre-filled panel w/ Save, X=delete w/ confirm alert).
- Avatars: 12 drawn faces (solid color + minimalist SwiftUI shapes — smile/laugh/
  sunglasses/wink/heart-eyes/etc). Runtime lesson: ghost.fill & skull.fill DON'T exist;
  validate with `NSImage(systemSymbolName:)`. Wink = one round eye + one tilted capsule
  (capsule OVER a circle just reads squashed). Smile arc must sit below eyes (0.44w frame
  at y 0.47w — earlier 0.56w @ 0.40w overlapped the eyes).
- Data isolation: UserDataService + TasteProfileManager keys namespaced
  `profile.{uuid}.*`; first profile migrates legacy history; footer click → picker.
- Sidebar footer = ProfileFooter (avatar + name, click → selection). Trakt REMOVED
  entirely (Trakt now requires VIP to create apps) — TraktManager.swift deleted.

### mpv upgrade 0.38 → 0.41 (playback verified by user ✅)
- Vendored `LocalPackages/LocalMPVKit` REPLACED by remote SPM dep:
  `mpvkit/MPVKit` pinned **exactVersion 1.0.0**, product **MPVKit-GPL** (samba parity).
- Code change: `import MPVKit` → **`import Libmpv`** (the framework's own modulemap
  exposes module `Libmpv`; upstream's `_MPVKit-GPL` target is a dummy that just links).
- pbxproj gotchas: remote package needs BOTH an `XCRemoteSwiftPackageReference` entry
  AND a line in the project object's `packageReferences` array; the exception set's
  `target` must be the PBXNativeTarget id (F7D62115…), not the group.
- SPM statically links the frameworks into `flux.debug.dylib` (326 mpv_* symbols);
  the 36K frameworks in Contents/Frameworks are link shims — that's NORMAL.
- Repo −452MB (LocalPackages deleted; it WAS git-tracked, deletions committed).

### App size: 1.6GB → 100MB (Debug)
- `hydra-server` (224MB) was stale in products — purged by clean rebuild.
- Xcode 16 filesystem-synchronized group on `flux/` copies ALL non-source files into
  Resources — LocalPackages leaked 1.36GB that way. Fix: moved LocalPackages to project
  root + `PBXFileSystemSynchronizedBuildFileExceptionSet` membershipExceptions
  (MPVKit-Swift, implementation_plan.md, SecretsExample.txt).
- Release build still needs a size/playback re-check (debug dylib is 87MB of that 100MB).

### Ghost loading UI (Components/GhostViews.swift)
- Shimmer modifier + GhostPoster/GhostCard/GhostHero/GhostRail/GhostGrid.
- Wired IN-PLACE (inside scroll content) on Home (hero+rails), Movies/TV/Trending
  (hero+grid), Search + MediaList (grids). ContentLoader overlay removed from all —
  ghosts preview the real layout. ContentLoader.swift kept but currently unused.

### Other fixes this session
- Continue Watching thumbnails: CachedImage gained `fallbacks: [URL?]` ladder (walks
  candidates on failure; fixed wrong-cache bug — it read URLCache.shared instead of the
  session's FluxImageCache). Enrichment write-back via UserDataService.enrichHistory().
- Upcoming rail: `/discover/movie?primary_release_date.gte=today` (the /upcoming endpoint
  leaks already-released); empty rails hidden; unreleased filtered everywhere else;
  GlassCard "Coming YYYY" badge.
- Genre cards: bundled optimized art (Assets genre-*.imageset), fixed 160×240 → then
  Color.clear+aspectRatio overlay pattern (image intrinsic size was leaking into layout
  → broken shapes AND edge-click misses; contentShape fixes clicks), no icons, no zoom.
- Carousel arrows offset(y:-10) — content's bottom padding shifted their axis.
- App icon: flux-cascade.png (pre-shaped w/ alpha — scale only, NO mask) into all 10 sizes.

### NEXT / open
- **FUTURE PLAN — Cascade (personal Telegram debrid)**: personal-scale ONLY (own channel,
  own ingested library, encrypted blobs, Telethon userbot bridge w/ Range streaming,
  Stremio-style addon endpoint so Flux Mode consumes it natively). Precedents to study:
  stremio-telegram-debrid (Range proxy + split stitching), TheUploader (TDLib torrent→TG).
  Constraints: MTProto mandatory (Bot API getFile caps at 20MB); 2GB/4GB per file → split+stitch;
  10-50MB/s with parallel workers. DECISION: personal use only — multi-user/piracy-bot-sourced
  variant is off the table (legal + ban exposure).
- Release build: verify size + playback (mergeable-library behavior may differ).
- For You rail: live refresh after ♥ toggle.
- HTTP stream addon research: verify working public instances (WebStreamr, Nuvio, etc.).
- Account system decision (Firebase vs alternatives) + login/signup + guest users.
- Downloads page still a stub.

---

## Session: Aug 24, 2026 (evening) — UI Polish + For You Recommendations

### Outcome: ALL REPORTED UI ISSUES FIXED ✅ + taste-based recommendations shipped

### Fixed this session (user-reported)
1. **Keyboard shortcuts** — Cmd+R refresh (`.fluxRefresh` notification → `refreshToken` `.id()` recreates page),
   Cmd+1/2/3/4 Home/Movies/TV/Trending, Cmd+F Search (`.fluxNavigate`, object = SidebarItem).
   Registered in fluxApp `.commands` (CommandGroup after .newItem).
2. **Loading ring placement** — `ContentLoader` (Components/) used as `.overlay` on each page's
   ScrollView (NEVER inside scroll content — ScrollView proposes unlimited height so in-content
   centering fails; overlay fills the exact viewport). Pages: Home, Movies, TV, Trending, MediaList, Search.
3. **Search Browse genre cards** — old `Genre.imageURL`s were Unsplash *download links* (HTML pages).
   Now: all 12 images downloaded (w=640, ~1MB total) into `Assets.xcassets/genre-*.imageset`,
   rendered locally, zero network. Card is FIXED 160×240 (CarouselView does NOT apply itemWidth
   to content — flexible cards collapse inconsistently; always fix the frame inside the card).
4. **SF Symbols gotcha** — `ghost.fill` AND `skull.fill` DO NOT EXIST on this macOS. Validate with
   `NSImage(systemSymbolName:)`. Horror uses `eyes.inverse`.
5. **Continue Watching thumbnails** — two bugs: (a) CachedImage checked `URLCache.shared` (system
   cache, can hold stale redirect/HTML) instead of the session's own `FluxImageCache`; (b) fallback
   chain ran at URL-SELECTION time only — a dead metahub episode still (new shows have none) killed
   the card. CachedImage now takes `fallbacks: [URL?]` and WALKS the ladder on failure (memory →
   session disk cache → network → next candidate). ContinueWatchingCard passes 8-URL ladder.
6. **Unreleased content** — filtered from Home hero/rows, Movies, TV, Trending, MediaList.
   EXCEPTION: "Upcoming Movies" row keeps them by design. GlassCard shows "Coming YYYY" badge.
7. **Search polish** — autofocus on arrive, grid spacing unified 16→24.

### New feature: For You recommendations (TasteProfileManager.swift)
- Signals: ♥ Love (weight 5, button on DetailView next to watchlist — NOT in player per user),
  watch completion ≥70% (2.5), watchlist (affinity only), partial watch (0.5). ~45-day recency decay.
- Engine: seeds (4 loved + 4 completed) → parallel TMDB `/recommendations` per seed (that IS the
  collaborative signal — global viewing behavior) → merge, score = seed weight × rank decay +
  genre affinity ×0.3 + voteAverage ×0.2 → filter watched/watchlisted/unreleased → top 20.
- UI: "For You" rail below Continue Watching; title becomes "Because you watched X" when a seed
  exists. Hidden until ≥1 loved or ≥2 completed watches. Backfills seeds from existing history
  on first launch. See-All via MediaListView.ListType.fixed.
- MediaItem got `init(seed:...)` in an EXTENSION (custom init in the struct would kill the
  memberwise init that TMDBModels relies on).

### NEXT / open
- For You rail only refreshes on page load / Cmd+R — consider live refresh after ♥ toggle.
- WebStreamrMBG instance uptime; debrid support would be the big playback upgrade.
- Downloads page is still a stub (empty array).

---

## Session: Aug 24, 2026 — Streaming Backend Overhaul (Hydra → Stremio server.js)

### Outcome: PLAYBACK WORKS END-TO-END ✅
Three videos tested back-to-back — all started fast and played smooth. Streams list quickly.

### What the architecture is now
```
Flux.app (SwiftUI + mpv)
  ├── StremioServerManager — downloads server.js v4.20.17 from dl.strem.io on first
  │   run (bundling is not permitted), runs it under node with Flux's own APP_PATH
  │   (~/Library/Application Support/Flux/StremioServer), discovers port (11470+1..4)
  │   by diffing heartbeat-alive ports before/after launch. Self-heals via ensureRunning().
  ├── Addon queries stay CLIENT-side (like real Stremio): StreamManager fans out in
  │   parallel to Torrentio + Comet (+ any user addon with a stream resource).
  │   Cinemeta excluded (catalog/meta only).
  └── Torrent playback protocol (the critical part):
        1. GET /{infoHash}/create?torrent={magnet}&fileIdx={n}   (fire-and-forget!)
        2. mpv plays http://127.0.0.1:{port}/{infoHash}/{fileIdx}
        The server blocks the file response until pieces flow; mpv reports
        paused-for-cache → buffering overlay. NEVER await /create — it blocks
        until metadata arrives and stalls playback on slow swarms.
```

### The bug chain that was killing playback (all fixed)
1. **Stale binary** — builds went to `~/Library/Developer/Xcode/DerivedData/flux-bsql…/` but
   launches used a project-local `DerivedData/` with an Aug 23 binary. Deleted; also removed
   a stray copy in `~/Projects/addons/hydra/DerivedData/`. **Always launch from the Xcode
   DerivedData path shown by `xcodebuild -showBuildSettings → TARGET_BUILD_DIR`.**
2. **Missing /create step** — server.js does not auto-discover torrents; without create,
   mpv connected to nothing.
3. **torrentHash() returned "btih:HASH"** (regex match includes prefix) → create path was
   `/btih:HASH/create` → 404 → every source "dead". Now stripped.
4. **Probes marked hashes dead on create failure** → manual clicks skipped instantly.
   Now: create failures never mark dead; only real mpv playback failures do
   (recentlyDeadHashes, 10 min TTL). Manual selection bypasses the dead-skip entirely.
5. **Awaiting /create before playback** → "Connecting to source…" stall, then fallback;
   second click worked (torrent had registered server-side in the background).
   Fix: fire-and-forget create + immediate finishSelect.
6. **mpv had no network timeout** → dead swarm = infinite silent wait. Added
   `network-timeout=45` so auto-fallback triggers.

### Other changes this session
- **Single-instance lock**: flock on `~/Library/Application Support/Flux/.instance.lock`;
  a second launch exits immediately (fixes duplicate app instances).
- **Addons**: defaults are Cinemeta (catalog), Torrentio, Comet, WebStreamrMBG.
  MediaFusion removed (redundant). Hydra web scrapers removed (source/index.ts returns []).
- **Buffer progress**: overlay show/hide uses mpv `paused-for-cache`/`seeking`;
  fill uses `demuxer-cache-time / duration` (Stremio's exact mechanism) —
  **KNOWN ISSUE: fill not updating visually, next up** (see below).
- **IMDb ID cache** in TMDBEnricher (was a fresh TMDB round-trip per play → slow listing).
- **Flux Mode**: top health-ranked torrent picked instantly (create-race removed —
  /create returns 200 for any well-formed magnet, so racing proves nothing).

### NEXT: buffer loading bar shows no progress
Symptom: overlay logo fill stays at 0 until playback starts. Data source should be
`demuxer-cache-time` (observed in MPVVideoView → `demuxerCacheTime`) polled in
PlayerView's `loadingTimer` (0.5s). Investigate:
- Is `demuxer-cache-time` actually firing for `http://127.0.0.1:11470/...` streams?
  (Log it in handlePropertyChange.)
- PlayerView reads `mpv.demuxerCacheTime` — confirm the @Published change propagates
  through the SwiftUI struct (timer closure captures `mpv` ObservedObject — should work).
- Consider mpv `cache-pause-wait` / demuxer cache bounds; server.js serves via its own
  engine so cache-time should advance as pieces land.
- Fallback plan: poll server.js `/stats.json` (has per-torrent download progress) — but
  demuxer-cache-time is the Stremio-faithful path, try that first.

### Env / commands
- Build: `xcodebuild -scheme flux -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- Launch: `open "$(xcodebuild -showBuildSettings … | awk -F' = ' '/TARGET_BUILD_DIR/{print $2}')/flux.app"`
- Server log (manual runs): `/tmp/opencode/flux-stremio-server.log`
- Verify server: `curl http://127.0.0.1:11470/heartbeat`
- Verify create: `curl "http://127.0.0.1:11470/{hash}/create?torrent={urlencoded magnet}"`

*Last updated: Aug 24, 2026*
