# RAM Management Remediation Plan

## Goal

Keep Flux memory usage bounded during extended browsing and playback, while
preserving the existing fast-start prefetch and PiP behaviour.

## Findings to address

1. **Image-cache byte limit is not enforced.** `NSCache.totalCostLimit` is
   configured to 30 MB, but image insertions do not provide a cost. The cache
   is therefore limited only by its 80-object count; decoded hero images can
   consume tens of megabytes each.
2. **The local HTTP stream proxy has no backpressure.** Upstream chunks are
   enqueued to a serial send queue faster than the local connection may drain,
   allowing pending `Data` objects to grow without a fixed upper bound.
3. **Detail-page torrent prefetch can outlive cancellation.** Torrent creation
   runs as an untracked task before its stream is recorded, so navigating away
   or starting playback can leave a prefetch torrent running until the engine's
   idle timeout.
4. **Long-lived metadata and stream dictionaries have no eviction.** These
   are smaller than media buffers, but their memory rises over a long session.
5. **RAM Cache Mode adds a 512 MB engine cache.** This is intentional, but its
   UI should make the combined process-memory impact explicit.

## Implementation order

### 1. Enforce image-cache costs

- Add a helper that calculates decoded image cost as `width * height * 4`,
  using a checked, capped integer conversion.
- Insert every `NSImage` into `ImageInMemoryCache` with
  `setObject(_:forKey:cost:)`.
- Keep the 30 MB byte budget; lower the 80-item count if profiling shows image
  object overhead is material.
- Use a cache key that includes the requested decode dimension, or explicitly
  choose a single canonical decoded size per image URL. This prevents a 4K
  carousel decode from being retained and reused by a small card.
- Lower the featured-carousel decode target from 3840 to a display-aware cap
  unless profiling proves native 4K decoding is necessary.

**Acceptance:** visiting at least 30 distinct detail/carousel pages does not
make the image cache retain more than its configured byte budget, verified in
Instruments Allocations and with cache-cost logging in debug builds.

### 2. Add stream-proxy backpressure

- Do not enqueue unlimited `Data` sends from
  `urlSession(_:dataTask:didReceive:)`.
- Prefer a bounded buffer with a byte watermark. Suspend the upstream
  `URLSessionDataTask` at the high watermark and resume only after send
  completions bring queued bytes below the low watermark.
- Cancel the upstream task and clear queued data on connection failure,
  cancellation, or proxy shutdown.
- Add debug-only counters for queued bytes, high-water events, and active
  pipes.

**Acceptance:** throttle the local client while playing a proxied source; RSS
and queued bytes plateau at the chosen buffer limit instead of growing with
stream duration.

### 3. Make torrent prefetch ownership cancellable

- Store the torrent hash before beginning `/create`.
- Make creation part of the tracked prefetch task rather than an independent
  fire-and-forget task.
- After every awaited operation, verify that the prefetch key still matches and
  that the task has not been cancelled before registering/retaining a torrent.
- On cancellation, playback start, timeout, or failed warm-core construction,
  remove the recorded hash exactly once.
- Keep playback and prefetch torrent ownership separate so a prefetch cleanup
  cannot remove the torrent currently selected for playback.

**Acceptance:** open a detail page and immediately go back or press Play;
engine diagnostics show no orphan prefetch torrent and no second active swarm.

### 4. Bound session caches

- Replace `StreamManager.streamCache` with a small LRU/TTL cache keyed by
  media/season/episode; evict entries on memory warning and after a short TTL.
- Put bounded count/TTL policies on TMDB ID, item, and new-episode caches.
- Prune expired `lastPlayedStreams` and `recentlyDeadHashes` periodically
  rather than only when a key is revisited.
- Avoid caching full enriched episode/cast payloads when a compact catalogue
  representation is sufficient.

**Acceptance:** a scripted browse/search session spanning hundreds of titles
has a stable cache-entry count and a bounded retained-size trend.

### 5. Clarify and guard RAM Cache Mode

- Update the setting copy to state that it reserves up to 512 MB for torrent
  pieces in addition to mpv, image, and Go-runtime memory.
- Consider offering smaller choices (for example 64, 128, 256, 512 MB) rather
  than a single fixed allocation.
- Surface the current setting and sidecar memory in debug diagnostics.

**Acceptance:** users can predict the trade-off before enabling the setting;
the default remains disk-backed with RAM Cache Mode off.

## Verification plan

1. Establish a baseline RSS/footprint for Flux and FluxEngine at idle, browsing,
   detail-page prefetch, direct playback, proxied playback, PiP, and after close.
2. Run Instruments Allocations and Leaks through repeated carousel/detail-page
   navigation, then inspect retained `NSImage`, `Data`, `Stream`, and
   `MediaItem` instances.
3. Run the proxied-stream throttle scenario for at least ten minutes and record
   peak queued bytes and process footprint.
4. Run prefetch-cancellation cases: back navigation, immediate Play, title
   switching, auto-fallback, PiP transition, and app termination.
5. Add regression tests for cache-cost calculation, LRU/TTL eviction, and
   prefetch ownership/cancellation. Add an integration diagnostic for proxy
   high-water behaviour where practical.

## Non-goals

- Do not remove mpv's current 50 MB forward / 10 MB backward buffer limits.
- Do not remove warm-core prefetch or PiP; repair their ownership and cleanup.
- Do not treat disk torrent-cache size as RAM usage.
