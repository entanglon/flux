import Foundation
import Combine

struct DownloadItem: Identifiable, Codable {
    let id: String
    var title: String
    var seasonEpisode: String?
    var fileName: String
    var totalBytes: Int64
    var downloadedBytes: Int64
    var isComplete: Bool
    var addedAt: Date
}

/// Real download pipeline: streams a source URL (server.js torrent stream or
/// direct HTTP) to ~/Movies/Flux/ with live progress. Completed files are
/// picked up automatically by getLocalUrl for offline playback.
class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published var activeDownloads: [DownloadItem] = []
    @Published var completedDownloads: [DownloadItem] = []

    private var session: URLSession!
    /// task id -> download id
    private var taskMap: [Int: String] = [:]
    private let completedKey = "fluxCompletedDownloads"

    var downloadsDirectory: URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Flux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    override private init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 4 * 3600 // big remuxes over slow swarms
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        if let data = UserDefaults.standard.data(forKey: completedKey),
           let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            // Drop entries whose files were removed on disk
            completedDownloads = saved.filter {
                FileManager.default.fileExists(atPath: downloadsDirectory.appendingPathComponent($0.fileName).path)
            }
        }
    }

    private func saveCompleted() {
        if let data = try? JSONEncoder().encode(completedDownloads) {
            UserDefaults.standard.set(data, forKey: completedKey)
        }
    }

    // MARK: - Offline lookup (used by PlayerManager.play)

    func getLocalUrl(for item: MediaItem) -> URL? {
        let prefix = sanitizedTitle(item.title)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.lastPathComponent.hasPrefix(prefix) }
    }

    private func sanitizedTitle(_ title: String) -> String {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters))
            .joined(separator: " ")
        return safe.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Start / Cancel

    func startDownload(id: String, title: String, seasonEpisode: String? = nil, url: URL) {
        guard !activeDownloads.contains(where: { $0.id == id }),
              !completedDownloads.contains(where: { $0.id == id }) else { return }

        let base = sanitizedTitle(title)
        let name = seasonEpisode.map { "\(base) - \($0).mp4" } ?? "\(base).mp4"
        let item = DownloadItem(
            id: id, title: title, seasonEpisode: seasonEpisode,
            fileName: name, totalBytes: 0, downloadedBytes: 0,
            isComplete: false, addedAt: Date()
        )
        activeDownloads.append(item)

        let task = session.downloadTask(with: url)
        task.taskDescription = id
        taskMap[task.taskIdentifier] = id
        task.resume()
        print("[DownloadManager] Started: \(name)")
    }

    func removeCompleted(_ item: DownloadItem) {
        let dest = downloadsDirectory.appendingPathComponent(item.fileName)
        try? FileManager.default.removeItem(at: dest)
        completedDownloads.removeAll { $0.id == item.id }
        saveCompleted()
    }

    func cancel(id: String) {
        session.getAllTasks { tasks in
            if let task = tasks.first(where: { $0.taskDescription == id }) {
                task.cancel()
            }
        }
        activeDownloads.removeAll { $0.id == id }
        taskMap = taskMap.filter { $0.value != id }
    }

    private func updateProgress(id: String, downloaded: Int64, total: Int64) {
        DispatchQueue.main.async {
            guard let idx = self.activeDownloads.firstIndex(where: { $0.id == id }) else { return }
            self.activeDownloads[idx].downloadedBytes = downloaded
            self.activeDownloads[idx].totalBytes = max(total, downloaded)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = taskMap[downloadTask.taskIdentifier] else { return }
        updateProgress(id: id, downloaded: totalBytesWritten, total: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = taskMap[downloadTask.taskIdentifier],
              let idx = activeDownloads.firstIndex(where: { $0.id == id }) else { return }

        let item = activeDownloads[idx]
        let dest = downloadsDirectory.appendingPathComponent(item.fileName)

        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async {
                var finished = item
                finished.isComplete = true
                finished.downloadedBytes = finished.totalBytes
                self.activeDownloads.removeAll { $0.id == id }
                self.completedDownloads.insert(finished, at: 0)
                self.saveCompleted()
                print("[DownloadManager] Completed: \(item.fileName)")
            }
        } catch {
            DispatchQueue.main.async {
                self.activeDownloads.removeAll { $0.id == id }
            }
            print("[DownloadManager] Move failed: \(error.localizedDescription)")
        }
        taskMap.removeValue(forKey: downloadTask.taskIdentifier)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = taskMap[task.taskIdentifier] else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        DispatchQueue.main.async {
            self.activeDownloads.removeAll { $0.id == id }
        }
        print("[DownloadManager] Failed: \(error.localizedDescription)")
        taskMap.removeValue(forKey: task.taskIdentifier)
    }
}
