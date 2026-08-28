# Flux — Active Session Journal

## LATEST: Aug 28, 2026 — CRASH FIX + PROCESS CLEANUP + TMDB VALIDATION

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

---

## Open Issues
1. **Search card art** — some titles have no metahub poster (shows gray placeholder)

## Done (cumulative)
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
