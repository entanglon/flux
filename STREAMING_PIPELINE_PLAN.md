# Flux Streaming Pipeline Acceleration Plan
**Objective:** Achieve ultra-fast, near-instant initial torrent playback start (< 2–3 seconds) without relying on paid Debrid services.

---

## 1. Anatomy of Torrent Streaming Latency (Cold-Start Breakdown)

When a user initiates playback of a BitTorrent magnet source, several asynchronous steps occur before the first frame renders:

| Stage | What Happens | Typical Delay | Target with Optimization |
| :--- | :--- | :--- | :--- |
| **1. Metadata Fetch (BEP 9)** | Engine queries DHT / Trackers to retrieve the 40-hex info dictionary (file tree, piece hashes). | 2.0 – 5.0s | **0.0 – 0.5s** (via edge cache / pre-warmed dictionary) |
| **2. Swarm Handshake** | TCP/uTP connections established, bitfields exchanged with seeders. | 1.0 – 3.0s | **0.5 – 1.0s** (via fast-peer discovery & tracker aggregation) |
| **3. Initial Header & Moov Atom** | Download pieces 0..N (container header, moov atom index) and trailing pieces (seek index). | 2.0 – 6.0s | **0.8 – 1.5s** (via piece prioritization & compact stream ranking) |
| **4. MPV Player Demux Buffer** | MPV buffers initial audio/video packets to begin hardware decoding. | 1.5 – 3.0s | **0.3 – 0.5s** (via `cache-pause-wait=1.0` tuning) |
| **Total Cold-Start Latency** | | **6.5 – 17.0s** | **⚡ 1.6 – 3.5s** |

---

## 2. Core Architectural Pillars

### Pillar A: "Fast Start" (Instant) Algorithmic Ranking & Source Tab
Not all torrents start at the same speed. A 40 GB 4K Remux with 16 MB piece sizes takes 10+ seconds just to download initial headers, while a 2.2 GB 1080p WebRip (with moov atom at byte 0 and 512 KB pieces) on a 150-seeder swarm starts in under 2 seconds.

#### 1. Startup Speed Score (SSS) Formula:
$$\text{Fast Start Score} = \left( \frac{\text{Seeders}}{\text{Size in GB} \times \text{BitrateFactor}} \right) \times \text{CodecModifier} \times \text{ReleaseGroupBonus}$$

* **BitrateFactor:** 4K = 2.5, 1080p = 1.0, 720p = 0.6.
* **ReleaseGroupBonus:** `+35%` bonus for streaming-optimized groups (`PSA`, `GalaxyRG`, `YTS`, `QxR`, `NTb`, `FLUX`, `MeGusta`) that place the container index at byte 0.
* **Size Sweet Spot:** 1.2 GB – 3.5 GB for Movies; 350 MB – 1.2 GB for TV Episodes.
* **Seeder Threshold:** Minimum $\ge 25$ seeders for "Fast Start" badge.

#### 2. UI Enhancements in Source Picker (`PlayerView.swift`):
* **New "Fast Start" Tab:** Sits next to "All" and "Best", instantly filtering to sources that start in $< 3$ seconds.
* **Latency Speed Badges:**
  * ⚡ **Instant (~1-2s):** Very high seeder density + compact size + fast moov header.
  * ⚡ **Fast (~3-4s):** High seeder density + 1080p Web-DL.
  * **Standard (~6-8s):** Large 4K files or lower seeder swarms.

---

### Pillar B: Edge Metadata Caching via Free Cloudflare Workers
* **Cloudflare Free Tier:** 100,000 requests/day at 0ms edge latency.
* **Mechanism:** 
  1. Flux queries Cloudflare Worker (`https://stream-racer.nemesys.workers.dev`) with the target `infoHash`.
  2. If the `.torrent` info dictionary is cached in Cloudflare KV / edge cache, the worker returns the raw torrent metadata.
  3. Flux injects the metadata directly into the streaming engine, completely skipping BEP 9 (DHT metadata search) and shaving **3 to 5 seconds** off startup.

---

### Pillar C: MPV Demuxer & Cache Buffer Tuning
Tune MPV options for instant first-frame playback without sacrificing long-term stability:
* `cache-pause-wait = 1.0` (Start playback as soon as 1.0s of video is buffered, rather than waiting for 5–10s).
* `demuxer-readahead-secs = 4.0` (Fast initial packet extraction).
* `cache-secs = 300` (Maintain a large 5-minute background buffer to prevent stalls once running).
* `demuxer-max-bytes = 150MiB` (Large demuxer cache for high-bitrate scenes).

---

### Pillar D: Detail-View & Hover Speculative Warmup
* When viewing a Detail page or selecting an episode, Flux already begins prefetching metadata.
* Extend this to pre-register (`/create`) the #1 ranked "Fast Start" torrent with low-priority background piece allocation.
* When the user presses "Play", the peer handshakes and container headers are **already loaded into memory** $\rightarrow$ instantaneous playback.

---

## 3. Step-by-Step Implementation Roadmap for Tomorrow

1. **Step 1: Stream Speed Scoring in `StreamManager.swift`**
   - Implement `computeStartupSpeedScore(for stream: Stream) -> Double`.
   - Add `estimatedStartupTime(for stream: Stream) -> TimeInterval`.
   - Categorize streams into `.instant`, `.fast`, and `.standard`.

2. **Step 2: "Fast Start" Tab & Badges in `PlayerView.swift`**
   - Add `"Fast Start"` filter tab in `dynamicFilters`.
   - Display speed badge on each stream row (e.g. `⚡ Instant (~2s)`).

3. **Step 3: MPV Player Buffer Tuning in `MPVVideoView.swift` / `PlayerManager.swift`**
   - Optimize `cache-pause-wait`, `demuxer-readahead-secs`, and initial buffer thresholds.

4. **Step 4: Edge Torrent Metadata Resolver Hook**
   - Wire `streamRacerUrl` in `StreamManager.swift` to resolve torrent metadata dictionaries for top candidate infoHashes.

5. **Step 5: Verification & Benchmarking**
   - Run automated unit tests (`xcodebuild test`).
   - Benchmark cold-start times across different popular and niche titles.
