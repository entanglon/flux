import SwiftUI

struct HistoryView: View {
    @ObservedObject private var userData = UserDataService.shared
    
    var showAsContinueWatching: Bool = false
    @Environment(\.openWindow) private var openWindow
    @State private var showClearConfirm = false
    
    enum Filter: String, CaseIterable {
        case all = "All"
        case inProgress = "In Progress"
        case completed = "Watched"

        var localizedTitle: String { rawValue.localized }
    }
    
    @State private var activeFilter: Filter
    
    init(showAsContinueWatching: Bool = false) {
        self.showAsContinueWatching = showAsContinueWatching
        _activeFilter = State(initialValue: showAsContinueWatching ? .inProgress : .all)
    }
    
    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 280), spacing: 24)]
    }
    
    private var filteredItems: [MediaItem] {
        switch activeFilter {
        case .all:
            return userData.history
        case .inProgress:
            return userData.continueWatching
        case .completed:
            return userData.recentlyWatched
        }
    }
    
    var body: some View {
        Group {
            if userData.history.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    LibraryPageHeader(
                        title: showAsContinueWatching ? "Continue Watching".localized : "Recently Watched".localized
                    )

                    Spacer()

                    LibraryEmptyState(
                        icon: "clock.arrow.circlepath",
                        title: showAsContinueWatching ? "No In-Progress Titles".localized : "No Watch History".localized,
                        message: "Movies and TV shows you start watching will automatically appear here.".localized
                    )

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
                            title: showAsContinueWatching ? "Continue Watching".localized : "Recently Watched".localized,
                            itemCount: userData.history.count,
                            itemLabel: "ITEMS",
                            rightAction: {
                                Button(role: .destructive) {
                                    showClearConfirm = true
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 12, weight: .bold))
                                        Text("Clear".localized)
                                            .font(.system(size: 13, weight: .bold))
                                    }
                                    .foregroundStyle(.white.opacity(0.75))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(Capsule().fill(Color.white.opacity(0.06)))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            },
                            filterChips: {
                                HStack(spacing: 8) {
                                    ForEach(Filter.allCases, id: \.self) { filter in
                                        let count: Int = {
                                            switch filter {
                                            case .all: return userData.history.count
                                            case .inProgress: return userData.continueWatching.count
                                            case .completed: return userData.recentlyWatched.count
                                            }
                                        }()
                                        
                                        Button {
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                                 activeFilter = filter
                                             }
                                         } label: {
                                             HStack(spacing: 6) {
                                                 Text(filter.localizedTitle)
                                                     .font(.system(size: 13, weight: activeFilter == filter ? .bold : .medium))
                                                 Text("\(count)")
                                                     .font(.system(size: 11, weight: .bold))
                                                     .opacity(activeFilter == filter ? 0.9 : 0.5)
                                             }
                                             .foregroundStyle(activeFilter == filter ? .white : .white.opacity(0.65))
                                             .padding(.horizontal, 16)
                                             .padding(.vertical, 8)
                                             .background(
                                                 Capsule()
                                                     .fill(activeFilter == filter ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
                                             )
                                             .overlay(
                                                 Capsule()
                                                     .stroke(activeFilter == filter ? Color.white.opacity(0.35) : Color.clear, lineWidth: 1)
                                             )
                                         }
                                         .buttonStyle(.plain)
                                     }
                                 }
                             }
                         )
                         
                         if filteredItems.isEmpty {
                             VStack(spacing: 12) {
                                 Text(String.localizedFormat("No %@ titles in your history", activeFilter.localizedTitle.lowercased()))
                                     .font(.system(size: 18, weight: .semibold))
                                     .foregroundStyle(.white.opacity(0.8))
                                 Button("Show All History".localized) {
                                     withAnimation { activeFilter = .all }
                                 }
                                 .font(.system(size: 13, weight: .bold))
                                 .foregroundStyle(Color.accentColor)
                                 .buttonStyle(.plain)
                             }
                             .frame(maxWidth: .infinity)
                             .padding(.vertical, 60)
                         } else {
                             LazyVGrid(columns: columns, spacing: 32) {
                                 ForEach(filteredItems) { item in
                                     let isItemInProgress = (activeFilter == .inProgress || (activeFilter == .all && !userData.isWatched(item)))
                                     Button(action: {
                                         PlayerManager.shared.play(
                                             item,
                                             season: item.lastSeason,
                                             episode: item.lastEpisode,
                                             episodeImage: item.lastEpisodeImage,
                                             fromContinueWatching: isItemInProgress
                                         )
                                         openWindow(id: "player", value: item.id)
                                     }) {
                                         ContinueWatchingCard(item: item, mode: isItemInProgress ? .continueWatching : .recentlyWatched)
                                     }
                                     .buttonStyle(.plain)
                                     .focusEffectDisabled()
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
        .alert("Clear Watch History?".localized, isPresented: $showClearConfirm) {
            Button("Clear All".localized, role: .destructive) {
                for item in userData.history {
                    userData.removeFromHistory(item)
                }
            }
            Button("Cancel".localized, role: .cancel) {}
        } message: {
            Text("This will remove all titles from your recently watched history.".localized)
        }
    }
}

#Preview {
    HistoryView()
}
