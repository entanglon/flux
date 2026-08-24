# Flux Project Handover

> [!CAUTION]
> **STRICT UI PRESERVATION WARNING**: Never modify existing UI components, card layouts, or premium aesthetics without explicit user permission. The current design has been meticulously tuned for a "premium" feel. 
>
> **LAUNCH PATH WARNING**: Builds land in `~/Library/Developer/Xcode/DerivedData/flux-bsql…/Build/Products/Debug/flux.app` (get the exact path via `xcodebuild -showBuildSettings`). A stale project-local `DerivedData/` caused days of phantom bugs — it has been deleted; never recreate it.

The app is a self-contained macOS Stremio-class client: SwiftUI + embedded mpv + the official
Stremio streaming server (server.js) as the local torrent engine.

## Architecture (as of Aug 24, 2026)
- **Streaming backend**: `StremioServerManager` downloads `server.js` (v4.20.17) from
  `https://dl.strem.io/server/v{ver}/desktop/server.js` on first run (bundling is not
  permitted by Stremio), runs it under node with Flux's own `APP_PATH`, discovers its port
  (11470, increments to 11474 on conflict) and self-heals via `ensureRunning()`.
- **Torrent protocol** (Stremio-exact, see `task.md` for the full bug chain):
  fire-and-forget `GET /{infoHash}/create?torrent={magnet}&fileIdx={n}`, then mpv plays
  `/{infoHash}/{fileIdx}`. Never await /create — it blocks on swarm metadata.
- **Addons are client-side**: `StreamManager` fans out in parallel to Torrentio, Comet,
  WebStreamrMBG (+ user addons with a stream resource). Cinemeta = catalog/meta only.
  Addon list managed in `AddonManager` (defaults auto-heal on launch).
- **Single instance**: flock on `~/Library/Application Support/Flux/.instance.lock`.
- **Hydra is DEPRECATED** (gitignored, kept on disk for reference): its web scrapers are
  replaced by WebStreamrMBG; its WebTorrent engine is replaced by server.js.
- **Metadata**: TMDB enrichment (cast/providers/backdrops/episode overviews) with IMDb-ID
  caching; Trakt sync via device OAuth.

## Recent Milestones (Aug 23-24)
- **Playback works end-to-end** via Stremio server.js: create → mpv → smooth playback,
  verified across multiple titles. Buffering overlay driven by mpv `paused-for-cache`.
- **Fixed the "source is dead" chain**: torrentHash prefix bug (create 404), probe-induced
  dead-marking, dead-skip now auto-selection-only, create failures no longer poison hashes.
- **Fast stream listing**: parallel addon fan-out + IMDb-ID cache + Cinemeta excluded.
- **Flux Mode simplified**: top health-ranked torrent plays immediately; mpv
  (`network-timeout=45`) + `onPlaybackError` drive auto-fallback — Stremio behavior.

## Known Open Issues
1. **Buffer loading bar fill doesn't move** — overlay shows/hides correctly, but the logo
   fill (demuxer-cache-time/duration) isn't updating visually. Next session's first task;
   investigation plan in `task.md`.
2. WebStreamrMBG public instance (baby-beamup.club) has had uptime issues — HTTP streams
   depend on it; Torrentio/Comet torrents are unaffected.

## 🛠️ Developer Handbook (Contributor Guide)

### 🚀 Setup & Execution
1. **API Keys**: `Secrets.swift` (gitignored) or via Settings. `SecretsExample.txt` documents keys.
2. **Node**: required for server.js — resolved from nvm/homebrew paths in `StremioServerManager`.
3. **Build**: `xcodebuild -scheme flux -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`, then launch from TARGET_BUILD_DIR.
4. **First run** downloads server.js (~6.5MB) to `~/Library/Application Support/Flux/`.

### 📝 Git Strategy (Keep History Clean)
- **Atomic Commits**: Each commit should address one specific feature or fix.
- **Descriptive Messages**: Use conventional commits if possible (e.g., `feat: episode cards`, `fix: trakt sync`).
- **Review Before Commit**: Always run a build check to ensure no "let vs var" regressions.

### 🎨 The "Premium UI" Manifesto
The "Flux Native" aesthetic is based on **Glassmorphism** and **Liquid Layouts**. 
- **Card Constraints**: `EpisodeCard` and `LiquidEpisodeCard` have hardcoded aspect ratios (16:9 for landscape, 1:1 for square). **DO NOT** change these without a direct order.
- **Typography**: Titles use 22pt Bold with negative tracking. Descriptions use 14pt Semi-Bold with subtle opacity.
- **Hover States**: All interactions must have a hover/focal state (chevrons, dimming, play buttons).

### 📋 Tracking Session State
- **`task.md`**: This is the current "Active TODO". Always check it first when starting a session.
- **`handover.md`**: This is the "Long-term Memory". Always update it before ending a session.

## Pending Tasks (Next Session)
1. **Buffer loading bar**: make the overlay fill reflect real buffered data (plan in `task.md`).
2. **Adaptive Homepage**: Refactor `HomeView` to dynamically iterate through all `enabledAddons`.
3. **Download Manager**: Implement background downloading for offline viewing.

*Last Updated: Aug 24, 2026*
