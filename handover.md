# Flux Project Handover - Restoration Complete

The application has been successfully restored to its stable, Stremio-native state following a significant codebase regression.

## Current State
- **Architecture**: Strictly Stremio-native. All metadata and streams are fetched via the Stremio Addon Protocol.
- **Models**: `MediaItem` uses String-based IDs (IMDb/Stremio) and contains all necessary metadata fields.
- **Build**: Successfully buildable on macOS (arm64). Common compiler timeout issues and missing dependency errors have been resolved.
- **Services**:
    - `StremioService.swift`: Core logic for Cinemeta and addon catalogs.
    - `StreamManager.swift`: Parallel stream aggregation with metadata parsing (Quality, Size, Language).
    - `Secrets.swift`: Central location for bridge URLs and API keys.

## Restored Features
- [x] **JustWatch Bridge**: "Where to Watch" button in `DetailView`.
- [x] **Cast Initials**: Initials-based avatar fallback in `DetailView`.
- [x] **Performance**: `LazyVStack` in player stream lists to prevent lag.
- [x] **Search**: Aggregated search across movies and TV shows using Cinemeta.

## Pending Tasks (Roadmap)
1. **Adaptive Homepage**: Refactor `HomeView` to dynamically iterate through all `enabledAddons` and display their catalogs, rather than relying on hardcoded defaults.
2. **Metadata Toggle Settings**: Add a toggle in `SettingsView` to enable/hide Cast and external sources. Rich TMDB metadata (including photos) should be an optional, user-configured feature requiring a TMDB API key.
3. **Trakt Integration**: Finalize the Trakt device auth flow and history syncing without Firebase.
4. **Player Improvements**: Support for addon-provided subtitles and refined stream racing logic.

## Critical Notes for Future Edits
- **Do not re-introduce `TMDBClient` or `TMDBEnricher`** as core dependencies. Any TMDB enrichment must be handled as an optional, opt-in layer.
- **Maintain String IDs** throughout the persistence and view layers to remain compatible with Stremio IDs.

*Last Updated: April 18, 2026*
