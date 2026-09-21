# Flux Project Handover & Session Summary

## 1. Overview of Completed Work

### A. Stream Picker Background Isolation & Race Cancellation
- **Problem**: When users clicked "Choose Stream Source…" from detail cards or "Choose Source" / context menus inside the video player, the background Flux Mode Auto-Play engine or early quorum race continued running in the background. Late-arriving streams triggered candidate races and MPV auto-play underneath the stream selection sheet.
- **Root Cause**:
  1. `PlayerManager.fetchAndRace`: The post-fetch Flux Mode auto-play engine (line 1195) and early quorum race commit (line 1106) lacked guards against `forceStreamPicker` and `isStreamPickerPresented`.
  2. The manual stream selection buttons failed to stop active MPV sessions or cancel in-flight scraper/probe background tasks.
- **Implementation**:
  - Added `PlayerManager.cancelAllPlaybackAndRaces()` to cancel `fetchAndRaceTask`, `startupWatchdogTask`, reset `hasCommittedAutoPlayWinner = false`, `isAutoPlayRaceActive = false`, clear `currentStreamURL`, and stop the active MPV player session.
  - Added checks for `!self.forceStreamPicker && !self.isStreamPickerPresented` across all race gates, early quorum commits, and `raceBestStream`.
  - Wired `cancelAllPlaybackAndRaces()` and `mpv.stop()` into the "Choose Source" error button, the right-click "Select Stream Source…" menu, and `PlayerManager.play(_:forceStreamPicker: true)`.

### B. "Choose Source" Button Layout Optimization
- **Problem**: The playback issue dialog (width: 480pt) displayed an overlong `"Choose Another Source"` button that wrapped into two lines, looking distorted and paragraph-like.
- **Implementation**:
  - Replaced label with `"Choose Source".localized` in `PlayerView.swift`.
  - Added `.lineLimit(1)` and `.fixedSize(horizontal: true, vertical: false)` to guarantee a single-line pill button.
  - Added translations for `"Choose Source"`, `"No HTTP streams available for this title"`, and `"Show Torrent Sources"` across all 10 supported languages in `LanguageManager.swift`.

### C. Multi-Token Title Conflict Penalty & Scraper Diagnosis
- **Investigation**:
  - Live testing for *Law & Order* S01E02 (`tt0098844:1:2`):
    - PenguPlay hosts (VidFast, Cinejoy, VAPlayer) were returning HTTP 500/502 errors or timing out.
    - CineFreak returned HTTP 200, but scraped an unrelated show: *"The First Order S01E01-05 WEB-DL Hindi ORG"*.
    - Previously, `StreamManager.evaluateTitleMatch` accepted any single token match (`"order"`), confirming "The First Order" as "Law & Order".
  - PenguPlay server status:
    - Popular cached titles (*Breaking Bad*) return streams.
    - Niche/older titles and unauthenticated endpoints return "You must sign in" or experience timeouts.
- **Implementation**:
  - Updated `StreamManager.evaluateTitleMatch`: 2-word titles (like "Law & Order") require complete token matches; conflicting candidates with $\le 50\%$ coverage receive an explicit conflict disqualification penalty (`-30,000.0`).
  - Updated `PlayerView.streamSelectionView`: When in HTTP mode and 0 HTTP streams exist but torrent streams do exist, the empty state displays a clear indicator and a one-click **"Show Torrent Sources"** button.

### D. Multi-Language Audio Preference Ranking & Secondary Languages
- Multi-language preference arrays stored in `UserDefaults.Key.preferredStreamLanguages`.
- `StreamManager.selectFastStartCandidate` rewards primary language (+5,000), secondary languages (+4,200), and authentic original language (+2,500), while penalizing unmatching foreign dubs (-3,500).
- Settings UI supports selecting and reordering multiple preferred audio languages.
- Fallback preserves foreign dubs as viable backup options if no preferred audio streams succeed.

---

## 2. Test Suite & Build Verification

- **`StreamManagerTests`**: All 45+ tests passed (`** TEST SUCCEEDED **`), including:
  - `titleMatchDisqualifiesConflictingMultiTokenTitles`
  - `cancelAllPlaybackAndRacesResetsPlaybackStateAndFlags`
  - `languageMatchingIgnoresSubtitleClauses`
  - `selectFastStartCandidatePreservesAndRanksUntaggedOriginalAudioIndianShow`
- **`LanguageManagerTests`**: All 18 localization tests passed across all 10 languages.
- **`fluxTests`**: Full test scheme passes.
- **`xcodebuild build -scheme flux`**: `** BUILD SUCCEEDED **`.

---

## 3. Files Modified
- `flux/Services/PlayerManager.swift`: Background race isolation, `cancelAllPlaybackAndRaces()`, picker guards.
- `flux/Services/StreamManager.swift`: Title conflict detection, multi-token overlap logic, multi-language ranking.
- `flux/Views/PlayerView.swift`: Single-line "Choose Source" button, empty state torrent reveal button, context menu cancellation.
- `flux/Services/LanguageManager.swift`: Localized strings for new buttons and empty state messages.
- `flux/Views/SettingsView.swift`: Multi-language selector UI.
- `fluxTests/StreamManagerTests.swift`: Unit tests for title conflict matching and player state isolation.
- `handover.md`: Session log and architectural documentation.
