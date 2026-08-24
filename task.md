# Flux — Active Session Journal

> Check this file first when starting a session. `handover.md` is long-term memory; this is the working state.

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
