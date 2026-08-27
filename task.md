# Flux — Active Session Journal

## LATEST: Aug 27, 2026 — PLAYER UI + MEMORY + TORRENT CLEANUP

### What was done this session

#### 1. Skip Intro & Next Episode — Apple TV Style
- Removed from player controls bar (subtitle/audio pill)
- Added as **floating bottom-right capsules** (like Apple TV's "Skip Recap")
- Only visible when player controls auto-hide (3s no mouse movement)
- Disappear when controls reappear on mouse move
- `isControlsVisible` is `@Binding` from PlayerView

#### 2. Memory Tightening
**FluxEngine (Go binary)**:
- `GOMEMLIMIT=500MB` (was 1GB — allowed 890MB usage)
- `GOGC=20` (GC at 20% growth, was 50/`off`)
- `STREMIO_MEM_LIMIT=500MB`
- Result: 25-30MB at idle (was 890MB)

**mpv**:
- demuxer-max-bytes: 100MB → 50MB
- demuxer-max-back-bytes: 20MB → 10MB

**Images**:
- Detail hero maxDimension: 4096 → 1920
- URLCache: 128MB → 32MB memory, 1GB → 512MB disk
- NSCache: 200/100MB → 80/30MB

#### 3. Double Torrent Download Fix
- Added `activeTorrentHash: String?` to PlayerManager
- `play()`: calls `cancelDetailPrefetch()` + `removeTorrent(oldHash)` before new playback
- `attemptStream()`: removes old torrent before registering new source
- `close()`: removes active torrent
- Prevents race: prefetch fire-and-forget /create vs play /create

#### 4. Search Improvements
- Dropdown suggestions while typing, hidden after submit
- Full on-page results only on Enter
- Typing after results resets to suggestion mode
- GlassCard maxDimension 800 → 1200 for Retina

#### 5. OTT Catalog Investigation
- Streaming Catalogs addon data is stale (third-party issue)
- Token expired Oct 2025, addon returns outdated content
- Not fixable from our side — addon maintainer issue

---

## Open Issues
1. **Search card art** — some titles have no metahub poster (shows gray placeholder)

## Done this session
- ✅ Downloads page — fully implemented (DownloadManager + DownloadsView + DetailView button)
- ✅ For You rail — live-refreshes after ♥ toggle (600ms debounce)
- ✅ RAM management — bounded caches, proxy backpressure, prefetch ownership (Codex)
- ✅ Continue Watching — progress bar already working (saved on player close)
- ✅ OTT catalogs — now via TMDB watch providers (always fresh), fixes stale addon
- ✅ Play Trailer — button on detail pages, opens YouTube trailer in browser
- ✅ Release build + DMG rebuilt (100MB app / 40MB DMG)

## What to test next
- Play a video → verify skip intro / next episode appear as floating bottom-right buttons
- Verify controls auto-hide shows the buttons, mouse movement hides them
- Check memory: flux app should be ~200-250MB, FluxEngine ~25MB at idle
- Navigate between detail pages → verify only one torrent downloads at a time
- Search: type → see dropdown → hit Enter → see full results → type again → dropdown returns

## Build & Run
```bash
# Build
xcodebuild -scheme flux -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Launch
pkill -f "MacOS/flux" 2>/dev/null; pkill -f "FluxEngine" 2>/dev/null; sleep 1
DEBUG_APP=$(xcodebuild -scheme flux -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 "TARGET_BUILD_DIR" | awk '{print $3}')/flux.app
open "$DEBUG_APP"
```

*Last Updated: Aug 27, 2026*
