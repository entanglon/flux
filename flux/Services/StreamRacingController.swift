import Foundation

/// Controller handling parallel stream health probes and head-to-head racing.
final class StreamRacingController {
    struct StreamProbeResult: Equatable {
        let ok: Bool
        let latency: Double
    }

    private(set) var probeStatus: [String: StreamProbeResult] = [:]

    /// Selects the best stream candidate based on health ranking and concurrent HTTP HEAD racing.
    func raceBestStream(
        from streams: [Stream],
        deadHashes: Set<String>,
        sourceMode: String,
        urlResolver: (Stream) -> URL
    ) async -> Stream? {
        let healthy = streams.filter { stream in
            guard let hash = stream.url.absoluteString.components(separatedBy: "btih:").last?.components(separatedBy: "&").first?.lowercased() else {
                return true
            }
            return !deadHashes.contains(hash)
        }
        guard !healthy.isEmpty else { return nil }

        if sourceMode != "http", let topTorrent = healthy.first(where: { $0.isTorrent }) {
            return topTorrent
        }

        guard sourceMode != "torrent" else { return nil }

        let httpCandidates = Array(healthy.filter { !$0.isTorrent }.prefix(3))
        guard !httpCandidates.isEmpty else { return nil }

        return await withTaskGroup(of: Stream?.self) { group in
            for stream in httpCandidates {
                let targetURL = urlResolver(stream)
                group.addTask {
                    var request = URLRequest(url: targetURL)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 3
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        if let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                            return stream
                        }
                        return nil
                    } catch {
                        return nil
                    }
                }
            }

            for await result in group {
                if let winner = result {
                    group.cancelAll()
                    return winner
                }
            }
            return nil
        }
    }
}
