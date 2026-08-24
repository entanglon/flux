import SwiftUI

struct HistoryView: View {
    @ObservedObject private var userData = UserDataService.shared
    
    var showAsContinueWatching: Bool = false
    @Environment(\.openWindow) private var openWindow
    
    var columns: [GridItem] {
        if showAsContinueWatching {
            return [GridItem(.adaptive(minimum: 280), spacing: 24)]
        } else {
            return [GridItem(.adaptive(minimum: 160), spacing: 24)]
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Header
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(showAsContinueWatching ? "Continue Watching" : "Recently Added")
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
                    VStack(spacing: 20) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.purple, .blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 72, height: 72)
                            .glassEffect(.clear, in: .circle)
                        
                        Text(showAsContinueWatching ? "No In-Progress Titles" : "No Watch History")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        
                        Text("Movies and TV shows you start watching will automatically appear here.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                    }
                    .padding(.vertical, 60)
                    .padding(.horizontal, 40)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.clear, in: .rect(cornerRadius: 24))
                    .padding(.top, 20)
                } else {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(userData.history) { item in
                            if showAsContinueWatching {
                                Button(action: {
                                    PlayerManager.shared.play(item, season: item.lastSeason, episode: item.lastEpisode, episodeImage: item.lastEpisodeImage)
                                    openWindow(id: "player", value: item.id)
                                }) {
                                    ContinueWatchingCard(item: item)
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink(value: item) {
                                    GlassCard(item: item, aspectRatio: .portrait)
                                }
                                .buttonStyle(.plain)
                            }
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
