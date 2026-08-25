# Flux Project Handover

> [!CAUTION]
> **STRICT UI PRESERVATION WARNING**: Never modify existing UI components, card layouts, or premium aesthetics without explicit user permission. The current design has been meticulously tuned for a "premium" feel. 
>
> **LAUNCH PATH WARNING**: Builds land in `~/Library/Developer/Xcode/DerivedData/flux-bsql…/Build/Products/Debug/flux.app` (get the exact path via `xcodebuild -showBuildSettings`). A stale project-local `DerivedData/` caused days of phantom bugs — it has been deleted; never recreate it.

The app is a self-contained macOS Stremio-class client: SwiftUI + embedded mpv + the official
Stremio streaming server (server.js) as the local torrent engine.

## Architecture (as of Aug 25, 2026)
- **Streaming backend**: `StremioServerManager` downloads `server.js` (v4.20.17) from
  `https://dl.strem.io/server/v{ver}/desktop/server.js` on first run (bundling is not
  permitted by Stremio), runs it under node with Flux's own `APP_PATH`, discovers its port
  (11470, increments to 11474 on conflict) and self-heals via `ensureRunning()`.
- **Torrent protocol** (Stremio-exact, see `task.md` for the full bug chain):
  fire-and-forget `GET /{infoHash}/create?torrent={magnet}&fileIdx={n}`, then mpv plays
  `/{infoHash}/{fileIdx}`. Never await /create — it blocks on swarm metadata.
- **Playback engine**: mpv **v0.41.0** + FFmpeg n8.1.2 via remote SPM dep
  `mpvkit/MPVKit` 1.0.0 (MPVKit-GPL product — samba parity). Import is
  `import Libmpv` (framework module), NOT MPVKit. SPM statically links the frameworks
  into the debug dylib; the small frameworks in Contents/Frameworks are link shims.
  The old vendored `LocalPackages/LocalMPVKit` is deleted (repo −452 MB).
- **Profiles (local, Netflix-style)**: `ProfileManager` gates the app behind
  `ProfileGateView` (select / create / manage-edit-delete). Data isolation via
  `profile.{uuid}.*` UserDefaults namespaces (history, watchlist, taste). First profile
  migrates legacy data. Sidebar footer shows the active profile → click returns to picker.
- **Addons are client-side**: `StreamManager` fans out in parallel to Torrentio, Comet,
  WebStreamrMBG (+ user addons with a stream resource). Cinemeta = catalog/meta only.
  Addon list managed in `AddonManager` (defaults auto-heal on launch).
- **Single instance**: flock on `~/Library/Application Support/Flux/.instance.lock`.
- **Hydra is fully removed** (code + bundle). Trakt removed (VIP-gated app creation).
- **Metadata**: TMDB enrichment with IMDb-ID caching; unreleased titles filtered from
  all feeds ("Coming YYYY" badge; the Upcoming row uses /discover gte=today and hides
  when empty).
- **Loading UX**: skeleton ghost cards everywhere (Components/GhostViews.swift) —
  wired in-place inside scroll content, not overlays.

## Recent Milestones (Aug 24-25)
- **mpv 0.41 upgrade verified by user** — playback smooth after the swap.
- **App size 1.6 GB → 100 MB** (stale hydra bundle purged; LocalPackages moved out of
  the filesystem-synchronized `flux/` folder + membership exceptions in pbxproj).
- **Local profiles**: selection/creation/manage UI, per-profile data, drawn face avatars.
- **Ghost loading UI** across Home/Movies/TV/Trending/Search/MediaList.
- **For You recommendations** (`TasteProfileManager`): ♥ on DetailView, watch completion,
  watchlist → TMDB /recommendations per seed; "For You" + "Because you watched X" rails.
- **Cache size limiter** (Settings → Advanced, 1–50 GB, live-applied).
- **Keyboard shortcuts**: Cmd+R refresh, Cmd+1–4 pages, Cmd+F search.
- **Thumbnail ladder** in CachedImage (`fallbacks:`) fixed Continue Watching artwork.

## Known Open Issues
1. **Release build unverified** after the mpv swap + size work — re-check size & playback.
2. For You rail refreshes on page load / Cmd+R only — live refresh after ♥ toggle pending.
3. WebStreamrMBG public instance has had uptime issues — HTTP streams depend on it.
4. Downloads page is a stub. Account system (Firebase vs alternatives) undecided.

## 🛠️ Developer Handbook (Contributor Guide)

### 🚀 Setup & Execution
1. **API Keys**: `Secrets.swift` (gitignored) or via Settings. `SecretsExample.txt` documents keys.
2. **Node**: required for server.js — resolved from nvm/homebrew paths in `StremioServerManager`.
3. **Build**: `xcodebuild -project flux.xcodeproj -scheme flux -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`, then launch from TARGET_BUILD_DIR (`~/Library/Developer/Xcode/DerivedData/flux-bsql…/Build/Products/Debug/flux.app`).
4. **First run** downloads server.js (~6.5MB) to `~/Library/Application Support/Flux/` and shows profile creation.

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
1. **Release build verification** (size + playback) after the mpv 0.41 swap.
2. **Account system**: pick backend (Firebase vs free alternatives), login/signup pages, guest users.
3. **Live For You refresh** after ♥ toggle; adaptive homepage; download manager.

*Last Updated: Aug 25, 2026*
