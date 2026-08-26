import SwiftUI

struct DownloadsView: View {
    @ObservedObject private var downloadManager = DownloadManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Header
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Downloads")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(.white)

                    let total = downloadManager.activeDownloads.count + downloadManager.completedDownloads.count
                    if total > 0 {
                        Text("\(total) ITEMS")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .glassEffect(.clear, in: .capsule)
                    }
                    Spacer()
                }
                .padding(.top, 48)

                if downloadManager.activeDownloads.isEmpty && downloadManager.completedDownloads.isEmpty {
                    emptyState
                } else {
                    if !downloadManager.activeDownloads.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Downloading")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)

                            ForEach(downloadManager.activeDownloads) { item in
                                activeRow(item)
                            }
                        }
                    }

                    if !downloadManager.completedDownloads.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Completed")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)

                            ForEach(downloadManager.completedDownloads) { item in
                                completedRow(item)
                            }
                        }
                    }
                }
            }
            .padding(.leading, 268)
            .padding(.trailing, 40)
            .padding(.bottom, 80)
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [.teal, .cyan], startPoint: .top, endPoint: .bottom))

            VStack(spacing: 6) {
                Text("No Downloads")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Download movies and episodes from any title's page to watch them offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(.top, 40)
    }

    // MARK: - Rows

    private func activeRow(_ item: DownloadItem) -> some View {
        let progress = item.totalBytes > 0 ? Double(item.downloadedBytes) / Double(item.totalBytes) : 0
        let sizeText = item.totalBytes > 0
            ? "\(ByteCountFormatter.string(fromByteCount: item.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))"
            : ByteCountFormatter.string(fromByteCount: item.downloadedBytes, countStyle: .file)

        return HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 64, height: 64)
                .overlay {
                    ProgressView().controlSize(.small)
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.seasonEpisode.map { "\(item.title) — \($0)" } ?? item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(Color.cyan)
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 5)

                Text(sizeText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                downloadManager.cancel(id: item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private func completedRow(_ item: DownloadItem) -> some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [.teal.opacity(0.5), .cyan.opacity(0.3)], startPoint: .top, endPoint: .bottom))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.seasonEpisode.map { "\(item.title) — \($0)" } ?? item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)) · \(item.fileName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                playDownloaded(item)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .help("Play offline copy")

            Button {
                DownloadManager.shared.removeCompleted(item)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private func playDownloaded(_ item: DownloadItem) {
        let media = MediaItem(seed: item.id, title: item.title, category: item.seasonEpisode != nil ? "TV Show" : "Movie")
        PlayerManager.shared.play(media)
    }
}
