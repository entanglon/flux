import Foundation
import OSLog

final class GeminiStreamRanker: @unchecked Sendable {
    static let shared = GeminiStreamRanker()
    
    private let session: URLSession
    
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 5.0
        self.session = URLSession(configuration: config)
    }

    /// Ranks streams using Google Gemini models with structured JSON output.
    /// Returns the AI-ranked streams at the top, followed by any remaining streams from the original list.
    func rankStreams(
        _ streams: [Stream],
        title: String,
        year: Int?,
        season: Int?,
        episode: Int?,
        apiKey: String,
        model: String = "gemini-3.5-flash-lite",
        preferredQuality: String? = nil,
        preferredLanguages: [String] = [],
        enableLanguageFilter: Bool = false,
        sourceMode: String = "both"
    ) async throws -> [Stream] {
        guard !streams.isEmpty else { return [] }
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { return streams }

        // 1. Source Mode Pre-Filter
        let modeFiltered: [Stream]
        if sourceMode == "http" {
            modeFiltered = streams.filter { !$0.isTorrent }
        } else if sourceMode == "torrent" {
            modeFiltered = streams.filter { $0.isTorrent }
        } else {
            modeFiltered = streams
        }
        let basePool = modeFiltered.isEmpty ? streams : modeFiltered

        // 2. Strict Resolution Cap Pre-Filter (Eliminates 4K releases when 1080p is selected)
        let maxAllowedQuality: Int?
        if let pq = preferredQuality, !pq.isEmpty, pq != "Auto" {
            maxAllowedQuality = StreamManager.shared.qualityScore(pq)
        } else {
            maxAllowedQuality = nil
        }

        let qualityFiltered: [Stream]
        if let maxAllowed = maxAllowedQuality, maxAllowed >= 3 {
            let capped = basePool.filter { StreamManager.shared.qualityScore($0.quality) <= maxAllowed }
            qualityFiltered = capped.isEmpty ? basePool : capped
        } else {
            qualityFiltered = basePool
        }

        // 3. Health & Viability Pre-Filter:
        // Filter out obvious junk/CAM, corrupt titles, Dolby Vision Profile 5, and severely dead torrents (< 5 seeders)
        let viableStreams = qualityFiltered.filter { s in
            if s.isTorrent {
                return (s.seeders ?? 0) >= 5
            }
            if StreamManager.shared.isDolbyVisionProfile5(s) {
                return false
            }
            if !title.isEmpty, StreamManager.labelLooksLikeJunk(labelText: s.fullScannableText, targetTitle: title) {
                return false
            }
            return true
        }
        let streamPool = viableStreams.isEmpty ? qualityFiltered : viableStreams
        // Bounded to top 12 streams to ensure ultra-low token count and < 2.0s latency
        let candidates = Array(streamPool.prefix(12))

        var candidateLines: [String] = []
        for (idx, s) in candidates.enumerated() {
            let label = s.cleanTitle.isEmpty ? s.title : s.cleanTitle
            let typeStr = s.isTorrent ? "torrent" : "http"
            var parts = ["[\(idx)]", label, s.quality, typeStr]
            if let size = s.size, !size.isEmpty {
                parts.append(size)
            }
            if s.isTorrent, let seeders = s.seeders {
                parts.append("seeders: \(seeders)")
            }
            if let codec = s.codec, !codec.isEmpty {
                parts.append(codec)
            }
            candidateLines.append(parts.joined(separator: " | "))
        }

        let mediaTarget: String
        if let s = season, let e = episode {
            mediaTarget = "\(title) (Season \(s), Episode \(e))\(year.map { " [\($0)]" } ?? "")"
        } else {
            mediaTarget = "\(title)\(year.map { " (\($0))" } ?? "")"
        }

        var userPrefsConstraints: [String] = []
        if let pq = preferredQuality, !pq.isEmpty, pq != "Auto" {
            userPrefsConstraints.append("- MAXIMUM RESOLUTION: \(pq). Candidates are pre-filtered to <= \(pq). Never choose or exceed 4K/2160p.")
        }
        if sourceMode == "torrent" {
            userPrefsConstraints.append("- STREAMING SOURCE: P2P Torrent Streams Only.")
        } else if sourceMode == "http" {
            userPrefsConstraints.append("- STREAMING SOURCE: Direct HTTP Streams Only.")
        }
        if enableLanguageFilter && !preferredLanguages.isEmpty {
            userPrefsConstraints.append("- PREFERRED LANGUAGES: [\(preferredLanguages.joined(separator: ", "))]. Strongly prefer releases or audio matching these.")
        }
        userPrefsConstraints.append("- STREAMABILITY: Prefer 1.5GB-8GB for movies, 400MB-2.5GB for TV episodes. Avoid 20+ GB uncompressed files.")
        userPrefsConstraints.append("- SEEDERS: For torrents, NEVER select releases with < 15 seeders. Prefer healthy swarms (> 25 seeders). If healthy torrents unavailable, prioritize direct HTTP.")
        let userPrefsPrompt = userPrefsConstraints.joined(separator: "\n")

        let systemPrompt = """
        Expert video stream ranker for: "\(mediaTarget)".
        Select the top 3 best stream indices that will play smoothly and accurately match the title.

        User Preferences:
        \(userPrefsPrompt)

        Evaluation Rules:
        1. Accurately match requested Season and Episode (reject wrong season/episode).
        2. Filter out CAM, TeleSync, and screeners.
        3. Match requested quality and language.
        4. Return JSON: {"top_indices": [0, 2], "reason": "brief sentence under 15 words"}
        """

        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "top_indices": [
                    "type": "ARRAY",
                    "items": ["type": "INTEGER"],
                    "description": "0-based indices of the top best streams in descending order of quality"
                ],
                "reason": [
                    "type": "STRING",
                    "description": "Short explanation under 15 words"
                ]
            ],
            "required": ["top_indices"]
        ]

        var generationConfig: [String: Any] = [
            "responseMimeType": "application/json",
            "responseSchema": schema,
            "maxOutputTokens": 200,
            "temperature": 0.0
        ]
        if model.contains("2.5") {
            generationConfig["thinkingConfig"] = ["thinkingBudget": 0]
        } else {
            generationConfig["thinkingConfig"] = ["thinkingLevel": "low"]
        }

        let promptPayload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": "\(systemPrompt)\n\nCandidates:\n\(candidateLines.joined(separator: "\n"))"]
                    ]
                ]
            ],
            "generationConfig": generationConfig
        ]

        let postData = try JSONSerialization.data(withJSONObject: promptPayload)

        do {
            return try await executeGenerateContent(
                model: model,
                apiKey: cleanKey,
                postData: postData,
                candidates: candidates,
                allStreams: streams,
                maxAllowedQuality: maxAllowedQuality
            )
        } catch {
            // Attempt ONE fast fallback model if the chosen model failed
            let fallbackModel = model.contains("2.5") ? "gemini-3.5-flash-lite" : "gemini-2.5-flash"
            Logger.stream.error("[GeminiStreamRanker] \(model, privacy: .public) failed (\(error.localizedDescription, privacy: .public)). Retrying with \(fallbackModel, privacy: .public)...")
            
            var fallbackGenConfig = generationConfig
            if fallbackModel.contains("2.5") {
                fallbackGenConfig["thinkingConfig"] = ["thinkingBudget": 0]
            } else {
                fallbackGenConfig["thinkingConfig"] = ["thinkingLevel": "low"]
            }
            var fallbackPayload = promptPayload
            fallbackPayload["generationConfig"] = fallbackGenConfig
            let fallbackData = try JSONSerialization.data(withJSONObject: fallbackPayload)

            if let result = try? await executeGenerateContent(
                model: fallbackModel,
                apiKey: cleanKey,
                postData: fallbackData,
                candidates: candidates,
                allStreams: streams,
                maxAllowedQuality: maxAllowedQuality
            ) {
                return result
            }
            throw error
        }
    }

    private func executeGenerateContent(
        model: String,
        apiKey: String,
        postData: Data,
        candidates: [Stream],
        allStreams: [Stream],
        maxAllowedQuality: Int?
    ) async throws -> [Stream] {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = postData

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard http.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "GeminiStreamRanker",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Gemini API HTTP \(http.statusCode): \(bodyText.prefix(120))"]
            )
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidateList = root["candidates"] as? [[String: Any]],
              let firstCandidate = candidateList.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw NSError(
                domain: "GeminiStreamRanker",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini candidate structure"]
            )
        }

        // Clean code block fences if present
        var cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanText.hasPrefix("```json") {
            cleanText = String(cleanText.dropFirst(7))
        } else if cleanText.hasPrefix("```") {
            cleanText = String(cleanText.dropFirst(3))
        }
        if cleanText.hasSuffix("```") {
            cleanText = String(cleanText.dropLast(3))
        }
        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let textData = cleanText.data(using: .utf8) else {
            throw NSError(
                domain: "GeminiStreamRanker",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to decode Gemini text as UTF-8"]
            )
        }

        var topIndices: [Int] = []
        var reasoning: String? = nil

        func extractIndices(from obj: Any) -> [Int] {
            var extracted: [Int] = []
            if let arr = obj as? [Any] {
                for item in arr {
                    if let n = item as? Int {
                        extracted.append(n)
                    } else if let s = item as? String, let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        extracted.append(n)
                    } else if let map = item as? [String: Any] {
                        if let n = map["index"] as? Int ?? map["id"] as? Int {
                            extracted.append(n)
                        } else if let s = (map["index"] as? String ?? map["id"] as? String), let n = Int(s) {
                            extracted.append(n)
                        }
                    }
                }
            }
            return extracted
        }

        if let dict = (try? JSONSerialization.jsonObject(with: textData)) as? [String: Any] {
            for key in ["top_indices", "indices", "top_stream_ids", "streams", "best_streams", "picks", "recommendations"] {
                if let val = dict[key] {
                    let list = extractIndices(from: val)
                    if !list.isEmpty {
                        topIndices = list
                        break
                    }
                }
            }
            reasoning = dict["reason"] as? String ?? dict["reasoning"] as? String
        } else if let arr = (try? JSONSerialization.jsonObject(with: textData)) as? [Any] {
            topIndices = extractIndices(from: arr)
        }

        // Regex fallback: extract any bracketed comma-separated integer array if structured decoding yielded no indices
        if topIndices.isEmpty {
            let pattern = #"\[\s*([0-9\s,]+)\s*\]"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: cleanText, range: NSRange(cleanText.startIndex..., in: cleanText)),
               let range = Range(match.range(at: 1), in: cleanText) {
                let numbersStr = cleanText[range]
                let nums = numbersStr.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if !nums.isEmpty {
                    topIndices = nums
                }
            }
        }

        guard !topIndices.isEmpty else {
            throw NSError(
                domain: "GeminiStreamRanker",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No stream indices extracted: \(cleanText.prefix(120))"]
            )
        }

        if let r = reasoning {
            Logger.stream.error("[GeminiStreamRanker] (\(model, privacy: .public)) AI reasoning: \(r, privacy: .public)")
        }

        var pickedStreams: [Stream] = []
        var pickedKeySet = Set<String>()

        for idx in topIndices {
            if idx >= 0 && idx < candidates.count {
                let stream = candidates[idx]
                // Hard Post-Filter: Discard any stream that somehow violates the quality ceiling
                if let maxAllowed = maxAllowedQuality, maxAllowed >= 3,
                   StreamManager.shared.qualityScore(stream.quality) > maxAllowed {
                    continue
                }
                if !pickedKeySet.contains(stream.stableKey) {
                    pickedStreams.append(stream)
                    pickedKeySet.insert(stream.stableKey)
                }
            }
        }

        guard !pickedStreams.isEmpty else {
            throw NSError(
                domain: "GeminiStreamRanker",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "None of the indices mapped to valid candidates"]
            )
        }

        // Retain unpicked streams at the end (partitioning compliant resolutions ahead of higher ones)
        let remaining = allStreams.filter { !pickedKeySet.contains($0.stableKey) }
        let (compliantRemaining, higherRemaining) = remaining.reduce(into: ([Stream](), [Stream]())) { acc, s in
            if let maxAllowed = maxAllowedQuality, maxAllowed >= 3, StreamManager.shared.qualityScore(s.quality) > maxAllowed {
                acc.1.append(s)
            } else {
                acc.0.append(s)
            }
        }
        return pickedStreams + compliantRemaining + higherRemaining
    }
}
