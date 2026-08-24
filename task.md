# Flux — Active Session Journal

> Check this file first when starting a session. `handover.md` is long-term memory; this is the working state.

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
