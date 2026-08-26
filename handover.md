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

## Recent Milestones (Aug 24-26)
- **OTT Explore rail** (Aug 26): 9 platforms (Netflix, Disney+, Prime Video, Apple TV+,
  HBO Max, Hulu, Peacock, Paramount+, Crunchyroll) with real branded logos in Home.
  Portrait cards (2:3), full-bleed images, GlassCard hover. Catalog pages preserve
  platform's native popularity order (no IMDb re-sort).
- **Hero/poster quality** (Aug 26): Backdrops upgraded to 4K (metahub large, 3840×2160).
  Posters use metahub large (780×1170) for all IMDb IDs — fixes low-res JustWatch OTT posters.
- **Native auth** (Aug 26): Cloudflare Worker with PBKDF2+JWT (no Firebase). AuthView
  redesigned as Instagram-style split card. Confirm password, email validation, show/hide
  toggles. Firebase Auth/Core/FirebaseFirestore fully removed from project.
- **Torrent cache eviction** (Aug 26): Client-side enforcement — sorts torrent dirs by
  modification date, evicts oldest until under limit. Runs at startup and on setting change.
- **OpenSubtitles fixed** (Aug 26): URL corrected from dead v3-opensubtitles.strem.io
  to working opensubtitles-v3.strem.io. Migration for persisted old URL.
- **Cinemeta-first metadata** (Aug 26): Home discovery rails use Cinemeta catalogs directly.
  TMDB enrichment guarded by `hasKey` — no-ops without a key. Key optional in Settings.
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
4. Downloads page is a stub. Account system is native (Cloudflare Worker PBKDF2+JWT).

### 🤖 AI Consultant Workflow
- **Claude and Qwen are available as external consultants**: when stuck on a major
  architectural decision, WRITE A SELF-CONTAINED PROMPT (full context, constraints,
  specific questions — assume the consultant knows nothing about Flux). Give the
  prompt to the USER, who sends it to each model and pastes back the replies.
  Weigh all responses together with our own analysis before deciding.
- Used for: Rust-vs-Go streaming-engine decision (Aug 26, 2026 — see task.md).

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
1. **PiP / mini floating player** (player PIP button is a stub; needs custom always-on-top mini window since mpv has no native PiP).
2. **Collections** (custom user lists) — SHIPPED, verify at runtime.
3. **Release build verification** (size + playback) after the mpv 0.41 swap.
4. Live For You refresh after ♥ toggle.
5. **Downloads page** — currently a stub, needs real implementation.

## Recent Additions (Aug 25, late)
- **OpenSubtitles**: subtitle search in the player (addon protocol, one-tap load).
- **Auto-play next episode** (countdown panel + Settings toggle) & **Skip Intro**.
- **Downloads**: stream-to-file manager with progress/cancel/persistence; offline
  playback auto-detected; Detail page download button (best stream, source-filter aware).
- **Person pages**: cast circles → hero (blurred backdrop, bio, facts) → filmography grid.
- **Season dropdown**: root-overlay floating panel (controller + direct frame writes).
- **Addons**: Meteor (torrents) + Stremify (HTTP) added after live verification;
  Flux Mode honors the HTTP/Torrent/Both source filter; foreign-dub health penalty.
- **TV genres** (Movies/TV toggle), **search autocomplete** (150ms, top 6),
  **NEW EPISODE badges** (TMDB last_episode_to_air, 7-day window), **per-profile
  playback settings** (snapshot/restore), **hydra fully removed**.

*Last Updated: Aug 26, 2026 (latest)*
