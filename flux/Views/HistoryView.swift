import SwiftUI

struct HistoryView: View {
    @ObservedObject private var userData = UserDataService.shared
    
    var showAsContinueWatching: Bool = false
    @Environment(\.openWindow) private var openWindow
    
    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 280), spacing: 24)]
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Header
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(showAsContinueWatching ? "Continue Watching" : "Recently Watched")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(.white)
                    
                    if !userData.history.isEmpty {
                        Text("\(userData.history.count) ITEMS")
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
                
                if userData.history.isEmpty {
                    // Apple TV Liquid Glass Empty State Card
                    LibraryEmptyState(
                        icon: "clock.arrow.circlepath",
                        title: showAsContinueWatching ? "No In-Progress Titles" : "No Watch History",
                        message: "Movies and TV shows you start watching will automatically appear here."
                    )
                } else {
                    LazyVGrid(columns: columns, spacing: 32) {
                        ForEach(userData.history) { item in
                            Button(action: {
                                PlayerManager.shared.play(item, season: item.lastSeason, episode: item.lastEpisode, episodeImage: item.lastEpisodeImage)
                                openWindow(id: "player", value: item.id)
                            }) {
                                ContinueWatchingCard(item: item, mode: showAsContinueWatching ? .continueWatching : .recentlyWatched)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                        }
                    }
                }
            }
            .padding(.leading, 268)
            .padding(.trailing, 40)
            .padding(.top, 40)
            .padding(.bottom, 60)
        }
        .background(Color.clear)
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .windowToolbar)
    }
}

#Preview {
    HistoryView()
}
