import SwiftUI

struct DownloadsView: View {
    @ObservedObject private var downloadManager = DownloadManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let total = downloadManager.activeDownloads.count + downloadManager.completedDownloads.count

        Group {
            if downloadManager.activeDownloads.isEmpty && downloadManager.completedDownloads.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    LibraryPageHeader(
                        title: "Downloads"
                    )

                    Spacer()

                    emptyState

                    Spacer()
                }
                .padding(.leading, LibraryScheme.leadingPadding)
                .padding(.trailing, LibraryScheme.trailingPadding)
                .padding(.top, LibraryScheme.topPadding)
                .padding(.bottom, LibraryScheme.bottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: LibraryScheme.headerBottomSpacing) {
                        LibraryPageHeader(
                            title: "Downloads",
                            itemCount: total > 0 ? total : nil,
                            itemLabel: "ITEMS"
                        )

                        if !downloadManager.activeDownloads.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Downloading")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.white)

                                ForEach(downloadManager.activeDownloads) { item in
                                    activeRow(item)
                                }
                            }
                        }

                        if !downloadManager.completedDownloads.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Completed")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.white)

                                ForEach(downloadManager.completedDownloads) { item in
                                    completedRow(item)
                                }
                            }
                        }
                    }
                    .padding(.leading, LibraryScheme.leadingPadding)
                    .padding(.trailing, LibraryScheme.trailingPadding)
                    .padding(.top, LibraryScheme.topPadding)
                    .padding(.bottom, LibraryScheme.bottomPadding)
                }
            }
        }
        .background(Color.clear)
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .windowToolbar)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        LibraryEmptyState(
            icon: "arrow.down.circle",
            title: "No Downloads",
            message: "Download movies and episodes from any title's page to watch them offline."
        )
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
                        Capsule().fill(Color.white.opacity(0.85))
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
                .fill(Color.white.opacity(0.08))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
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
