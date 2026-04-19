# Flux Project Handover - Restoration & Polishing Complete

> [!CAUTION]
> **STRICT UI PRESERVATION WARNING**: Never modify existing UI components, card layouts, or premium aesthetics without explicit user permission. The current design has been meticulously tuned for a "premium" feel. 

The application has been successfully restored to its stable, Stremio-native state and deeply polished with rich metadata and high-fidelity visuals.

## Recent Milestones (April 18-19)
- **Trakt Integration**: Successfully implemented Device OAuth flow (`8 digit PIN`). History now syncs correctly.
- **Episode UI Restoration**: Full restoration of the premium landscape design (380x214 glass overlays) with context-aware scrolling chevrons.
- **Metadata Enrichment**:
    - **Episode Overviews**: Implemented a per-season fetch from TMDB to fill in missing descriptions.
    - **Shared Metadata Bridge**: Implemented a fallback mechanism in `TMDBEnricher` that uses a shared public key if the user's personal key is missing. This keeps the app rich and functional for all users out of the box.
    - **Original Quality Banners**: Upgraded hero backdrops and episode stills to TMDB `original` resolution. Fixed a priority bug where low-res episode thumbnails were used as backgrounds.
- **Hero Carousel Refined**: Content is now filtered for "Latest" (2024+) and "Upcoming" releases, sorted by overall popularity (TMDB rank).
- **Trakt Thumbnail Bridge**: Fixed the "loading wheel" bug where Trakt IMDb IDs (`tt...`) failed to resolve episode thumbnails.

## 🛠️ Developer Handbook (Contributor Guide)

### 🚀 Setup & Execution
1. **API Keys**: Ensure `tmdbApiKey` is set in `Secrets.swift` or via the Settings menu.
2. **Environment**: App is designed for macOS (Apple Silicon). Use `npx` for any web-based bridge testing.
3. **Build**: Always build for `arm64` to prevent playback issues with the MPV bridge.

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

## Current Architecture
- **Stremio-Native Core**: Primary metadata source is Cinemeta; streams aggregated via Addon protocol.
- **Optional TMDB Layer**: Enrichment for Cast, Providers, Backdrops, and Episode Overviews.
- **Shared Bridge Fallback**: TMDB enrichment now works without individual user keys by falling back to a pre-configured shared bridge in `Secrets.swift`.
- **Persistence**: `UserDataService` manages local history and watchlist, synced with Trakt.

## Pending Tasks (Next Session)
1. **Adaptive Homepage**: Refactor `HomeView` to dynamically iterate through all `enabledAddons`.
2. **Player Refinements**: Support for external subtitle files and stream racing optimizations.
3. **Download Manager**: Implement background downloading for offline viewing.

*Last Updated: April 19, 2026 (02:15 PM)*
