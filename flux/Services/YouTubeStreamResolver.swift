import Foundation

enum YouTubeStreamResolver {
    private static let ytDlpPaths = [
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
        "/usr/bin/yt-dlp",
        "/opt/homebrew/bin/youtube-dl",
        "/usr/local/bin/youtube-dl"
    ]
    
    private static func findBinary() -> String? {
        let fileManager = FileManager.default
        for path in ytDlpPaths {
            if fileManager.fileExists(atPath: path) && fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    /// Resolves a direct playable MP4/HLS stream URL for a YouTube video key.
    static func resolveStreamURL(videoKey: String) async -> URL? {
        guard let binaryPath = findBinary() else {
            return URL(string: "https://www.youtube.com/watch?v=\(videoKey)")
        }
        
        let videoURL = "https://www.youtube.com/watch?v=\(videoKey)"
        
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = [
                    "-f", "best[ext=mp4]/best",
                    "--get-url",
                    "--no-playlist",
                    videoURL
                ]
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe() // Suppress stderr
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       let firstLine = output.components(separatedBy: .newlines).first,
                       let streamURL = URL(string: firstLine) {
                        continuation.resume(returning: streamURL)
                        return
                    }
                } catch {
                    print("[YouTubeStreamResolver] Failed to run yt-dlp: \(error)")
                }
                
                continuation.resume(returning: URL(string: videoURL))
            }
        }
    }
}
