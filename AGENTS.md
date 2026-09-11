# Flux — Agent Guidelines & Project Rules

## 1. MANDATORY: Localization-First Development
Whenever building new features, screens, views, sheets, alerts, settings tabs, diagnostic overlays, menus, or modifying existing UI in Flux:
- **Zero Hardcoded User-Facing Strings**: Every user-visible string must use `.localized` or `String.localizedFormat(...)` / `"...".localizedFormat(...)`. No raw English string literals should be rendered directly in SwiftUI views.
- **10-Language Translation Matrix**: Whenever introducing a new key, add corresponding translations across all 10 supported languages (`en`, `ja`, `es`, `fr`, `de`, `it`, `pt`, `ko`, `hi`, `zh`) in `flux/Services/LanguageManager.swift`.
- **Guard Against Swift Dictionary Literal Duplicates**: Swift does not detect duplicate keys in dictionary literals at compile time, but throws a fatal crash at runtime during initialization (`Fatal error: Dictionary literal contains duplicate keys`). Always verify keys are strictly unique before committing.
- **Preserve Internal Keys in Canonical English**: TMDB API parameters/genres, Stremio addon IDs/types (`movie`, `series`, `channel`), PocketBase schema fields, and UserDefaults system keys must remain canonical English. Only user-facing display text is localized.
- **Dynamic Language Observation**: Views must observe `LanguageManager.shared` (e.g., `@ObservedObject var languageManager = LanguageManager.shared`) so changing language in Settings (`⌘,`) dynamically updates the view in real-time without requiring an app restart.

---

## 2. MANDATORY: Push Back on User Requests
When the user asks for a change, DO NOT implement blindly. First:
1. **Evaluate the request** — Is it the right fix? Could the user be misidentifying a bug that's actually a feature?
2. **Warn about consequences** — What will break? What trade-offs exist? What's lost?
3. **Suggest alternatives** — If the user's proposed fix has downsides, propose a better approach.
4. **Ask before proceeding** — "Are you sure? Here's what will happen if I do this..."

---

## 3. Architecture & Build Guidelines
- **Target**: macOS 14.0+ desktop application written in SwiftUI.
- **Engine**: Embedded Go `FluxEngine` Stremio streaming server communicating over loopback HTTP/HTTPS (ports 11470 and 12470).
- **Video Player**: Native libmpv backend integrated via `LocalMPVKit`.
- **Metadata & Catalog**: TMDB API + Stremio Addon manifest bridge.
- **Cloud Sync**: PocketBase backend for cross-device watchlist, history, and profile sync.
- **Build Command**:
  ```bash
  xcodebuild -project flux.xcodeproj -scheme flux -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO build -quiet
  ```
- **Documentation**:
  - Always consult `handover.md` at the beginning of each session for recent architectural changes, known pitfalls, and completed work.
  - Keep `handover.md` updated at the end of each session.
