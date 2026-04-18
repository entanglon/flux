import Foundation

class DownloadManager {
    static let shared = DownloadManager()
    private init() {}
    
    func getLocalUrl(for item: MediaItem) -> URL? {
        // Implement offline download lookups here later
        return nil
    }
}
