# Flux — Roadmap

> Living plan doc for the Flux streaming app. First entry: **Cascade addon** —
> pull playback from Telegram-backed storage instead of torrents.

## Cascade addon — PLANNED (discussed 2026-08-22)

**Goal:** stream Flux's content from Telegram-backed storage ("Cascade cloud")
instead of torrent swarms, via an addon-style bridge. Torrent playback stays
available; anything played that isn't already stored gets persisted into
Telegram in the background.

**Where the reusable engine lives:** the companion project
`~/Projects/Cascade` (macOS app "Cascade" — private cloud drive on top of a
Telegram channel). Its `HANDOVER.md` + `AGENTS.md` are the entry points; this
session's counterpart agent should read those first. Key pieces to reuse:

- `Engine/VaultStreamServer.swift` — loopback HTTP **byte-range server**
  serving decrypted video off Telegram (Range/206 verified byte-perfect;
  deep-range prefetcher eliminates buffering). This is the same architecture
  Stremio uses internally.
- Chunker / UploadEngine (~1.9 GiB uniform chunks) with pause/resume +
  post-upload preheat.
- rootHash content dedupe (prevents re-uploading titles already stored).
- Subtitle sidecars (auto-materialize `.srt/.ass` next to videos).
- ShareLink crypto + pool-channel management (multi-channel patterns).

**Architecture sketch (user decisions):**

1. Dedicated STREAMING CHANNEL on Telegram, deliberately separate from
   Cascade's main personal vault channel (blast-radius isolation; keeps the
   personal catalog clean).
2. Ingestion = forward-based from Telegram movie bots into the streaming
   channel — server-side copies, zero re-upload (reuses Cascade's
   share-forward machinery).
3. Torrent-playback cache inversion: play directly from torrent while
   watching; any title not already in the channel is chunked up and uploaded
   in the background.
4. Flux ↔ bridge API: catalog listing + authenticated stream URLs. Flux plays
   via libmpv (bundled here as LocalMPVKit) — no transcoding needed
   client-side.

**Open questions for the implementation session:**

1. Protected-content flags on movie-bot channels block forwards — detection +
   fallbacks needed.
2. Cascade's stream server currently resolves against ITS vault channel only;
   extending it to serve an arbitrary channelID touches the fetcher core
   (careful — see Cascade HANDOVER items 160–166 for why that core is
   sensitive).
3. Upload ceilings: non-Premium `FLOOD_PREMIUM_WAIT` monthly throttle; bulk
   ingestion needs background-queue semantics.
4. Remote access shape: loopback-only first (same machine), then LAN /
   Tailscale — auth hardening grows with exposure.
5. Risk posture: keep the streaming channel single-user/self-hosted. Shared
   distribution channels are the ban magnet; account bans would take the
   whole vault with them. Content-provenance caveat stands.

---

## Secret Player Control Panel — COMPLETED (shipped Sep 11, 2026)

**Goal:** Add an advanced secret HUD / control panel inside the player for power-user playback tuning.
**Shipped in `SecretPlayerHUDView.swift`:**
1. **Diagnostics Tab ("Stats for Nerds"):** Video/audio codecs, hardware decoder verification (`videotoolbox`), resolution, framerate, dropped frame counts, demuxer buffer cache, and live bitrates.
2. **Subtitles Delay & Scale:** Quick ±50ms / ±100ms / ±500ms sync buttons, vertical positioning slider, text scaling slider, and custom offset input bar with unit switcher (`sec` / `ms`).
3. **Audio Delay Sync & Dialogue Boost:** Latency correction with custom offset input bar, volume amplifier indicator, and Dialogue Boost normalizer (amplifies quiet whispers, compresses loud sound effects).
4. **Video Filters & Geometry:** Aspect ratio overrides (`Auto`, `16:9`, `21:9`, `4:3`), Deband filter shader, and real-time contrast, brightness, and saturation adjustments.
5. **Trigger:** Floating control bar icon and `D` hotkey with edge-to-edge hit testing.

---

## Localization-First Architecture — PERMANENT STANDARD (shipped Sep 11, 2026)

**Mandatory Rule for All Future Features:**
Whenever designing or modifying any user-facing screen, component, sheet, alert, or menu in Flux:
1. **No Raw String Literals:** All UI labels must call `.localized` or `String.localizedFormat(...)` / `"...".localizedFormat(...)`.
2. **10-Language Matrix:** Add corresponding keys and translations across all 10 supported languages (`en`, `ja`, `es`, `fr`, `de`, `it`, `pt`, `ko`, `hi`, `zh`) in `flux/Services/LanguageManager.swift`.
3. **Unique Dictionary Keys:** Always ensure no duplicate keys exist in dictionary literals (runtime crash hazard in Swift).
4. **Internal English Preservation:** Keep TMDB API parameters, Stremio addon IDs, PocketBase model payloads, and system keys in canonical English.
5. **Reactive View Updates:** Ensure views observe `LanguageManager.shared` (`@ObservedObject var languageManager = LanguageManager.shared`) so language switching in Settings updates the UI instantly.

