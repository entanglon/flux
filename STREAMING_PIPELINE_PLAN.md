# Flux Streaming Pipeline Acceleration Plan (Refined & Production-Ready)
**Objective:** Achieve ultra-fast, near-instant initial torrent playback start (< 2–3 seconds) with robust failovers, zero-cost edge caching, and fine-tuned MPV demuxer parameters.

---

## 1. Real-World Cold-Start Latency Breakdown

| Stage | What Happens | Cold Delay | Refined Mitigation | Target Latency |
| :--- | :--- | :--- | :--- | :--- |
| **1. Metadata Fetch (BEP 9)** | Engine queries DHT / Trackers to retrieve the 40-hex info dictionary (file tree, piece hashes). | 2.0 – 5.0s | **Edge Cache Pre-fetch:** Query Cloudflare KV for cached info dictionary; client skips DHT lookup. | **0.1 – 0.5s** |
| **2. Swarm Handshake** | TCP/uTP connections established, bitfields exchanged with seeders. | 1.0 – 3.0s | **High-Seeder Prioritization:** Filter swarms with high active seeder density. | **0.5 – 1.0s** |
| **3. Container Header Download** | Download piece 0 (container header) and trailing pieces (if MP4 without faststart). | 2.0 – 6.0s | **Container-Aware Ranking:** Prefer MKV (SeekHead at byte 0) and faststart MP4s; penalize 40GB+ remuxes. | **0.6 – 1.5s** |
| **4. MPV Player Demux Buffer** | MPV demuxes first video/audio packets to begin hardware decoding. | 1.5 – 3.0s | **`cache-pause-initial=no`:** Render immediately on first keyframe without waiting for artificial buffer. | **0.2 – 0.4s** |
| **Total Startup Latency** | | **6.5 – 17.0s** | | **⚡ 1.4 – 3.4s** |

---

## 2. Core Architectural Pillars

### Pillar A: Container-Aware "Fast Start" Algorithmic Ranking

#### 1. Container & Codec Reality:
* **MKV (`.mkv`, Matroska):** By specification, Matroska places its `SeekHead` at **byte 0**. It does not require trailing pieces to start playback. It demuxes sequentially from the very first piece.
* **MP4 (`.mp4`, `.m4v`):** If the `moov` atom is at the end of the file (not `faststart`), the engine must download trailing pieces before playback. Releases from known streaming groups (`PSA`, `GalaxyRG`, `YTS`, `QxR`, `NTb`, `FLUX`, `MeGusta`) have `faststart` enabled.
* **Direct / HTTP:** Instant 0-second peer handshake.

#### 2. Startup Speed Score (SSS) Formula:
$$\text{FastStartScore} = \left( \frac{\text{Seeders}}{\text{Size in GB} \times \text{SizePenalty}} \right) \times \text{ContainerModifier} \times \text{ReleaseGroupBonus}$$

* **Seeders:** If `nil` or `0`, score = 0 (excluded from "Fast Start" tab).
* **ContainerModifier:** 
  * Direct / HTTP = `10.0` (Instant baseline).
  * MKV = `1.30` (Natural byte-0 streamability).
  * MP4 with FastStart Group = `1.25`.
  * Unknown MP4 / Generic = `0.85`.
* **Size Sweet Spot & Penalty:**
  * Movies: Ideal $1.0\text{ GB} - 3.5\text{ GB}$. Files $> 10\text{ GB}$ receive progressive penalty ($\times 0.5$).
  * TV Episodes: Ideal $350\text{ MB} - 1.2\text{ GB}$. Files $> 3.5\text{ GB}$ receive progressive penalty.
* **Seeder Threshold:** Minimum $\ge 25$ seeders for the `⚡ Instant` or `⚡ Fast` badge.

#### 3. Stream Picker UI Enhancements (`PlayerView.swift`):
* **New "Fast Start" Tab:** Sits alongside "All" and "Best", presenting only streams with `estimatedStartupTime <= 3.5s`.
* **Live Speed Tier Badges:**
  * ⚡ **Instant (~1-2s):** Direct streams, or $\ge 50$ seeder compact MKVs.
  * ⚡ **Fast (~3-4s):** $\ge 25$ seeder 1080p Web-DLs.
  * **Standard (~6-8s):** Large 4K files or smaller swarms.

---

### Pillar B: Production MPV Buffer & Watchdog Parameters

Correcting MPV parameters based on engine behavior:

```swift
// MPV Configuration in MPVVideoView.swift / PlayerManager.swift
mpv_set_option_string(handle, "cache-pause-initial", "no")      // Start frame 1 immediately without waiting for buffer
mpv_set_option_string(handle, "cache-pause-wait", "3.0")        // Tolerate up to 3s gap before re-pausing on stalls
mpv_set_option_string(handle, "demuxer-readahead-secs", "12.0") // Keep generous lookahead during playback
mpv_set_option_string(handle, "demuxer-max-bytes", "157286400") // 150 MiB RAM budget
mpv_set_option_string(handle, "demuxer-max-back-bytes", "31457280") // 30 MiB backward seek buffer
mpv_set_option_string(handle, "network-timeout", "15")          // Fail fast on dead swarms (reduced from 45s)
```

#### Hung-Stream Watchdog (Auto-Fallback in 10-12s):
* If `isBuffering == true` and `demuxerCacheTime` remains `0.0` for $> 12\text{ seconds}$ after `/create`, classify the stream as a stalled/dead swarm and automatically trigger fallback (`tryNextStream()`).

---

### Pillar C: Edge Torrent Metadata Caching (Cloudflare Worker)

* **Read Path:** When searching for streams, query `https://stream-racer.nemesys.workers.dev/metadata?hash={infoHash}`. If hit, inject raw `.torrent` info dictionary into engine, skipping BEP 9 DHT lookup.
* **Write Path (Client Write-Through):** When a Flux client successfully resolves a new torrent infoHash via DHT, it asynchronously POSTs the info dictionary with an HMAC auth header to the worker (7-day TTL).
* **Quota Protection:** Client caches responses locally with 24-hour TTL and ETags to stay well within the 100K free requests/day ceiling.

---

### Pillar D: Detail-View & Dwell Speculative Pre-buffering

* **Detail-View Background Warmup:** When a title's Detail page loads, Flux already primes the pipeline.
* **Episode Dwell Trigger:** On episode selection (dwell $> 1.5\text{s}$), pre-register the #1 ranked Fast-Start torrent with the streaming engine.
* **Warm Core Lifecycle:** Keep warm core in memory for 2 minutes or until memory pressure occurs, guaranteeing $< 500\text{ms}$ playback when "Play" is clicked.

---

## 3. Implementation Roadmap

1. **Step 1: Container-Aware Startup Speed Scoring (`StreamManager.swift`)**
   - Add `isMKV`, `isFastStartMP4`, `estimatedStartupTime` properties.
   - Implement `computeStartupSpeedScore()` with robust `nil` seeder handling.
2. **Step 2: "Fast Start" Filter Tab & Latency Badges (`PlayerView.swift`)**
   - Add `"Fast Start"` tab in `dynamicFilters`.
   - Render `⚡ Instant (~1-2s)` and `⚡ Fast (~3-4s)` badges in the source row.
3. **Step 3: MPV Buffer Optimization & Hung-Stream Watchdog (`MPVVideoView.swift`, `PlayerManager.swift`)**
   - Apply `cache-pause-initial = no`, `network-timeout = 15`, and 12s cache stall auto-fallback watchdog.
4. **Step 4: Edge Metadata Cache Integration (`StreamManager.swift`)**
   - Wire `streamRacerUrl` metadata resolution with client-side cache fallback.
5. **Step 5: Verification & Automated Tests**
   - Run test suite with `xcodebuild test`.
   - Verify zero regressions across all 25 unit tests.
