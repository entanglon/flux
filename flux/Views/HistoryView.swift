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
    }
    
    @State private var activeFilter: Filter = .all
    
    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 280), spacing: 24)]
    }
    
    private var filteredItems: [MediaItem] {
        switch activeFilter {
        case .all:
            return userData.history
        case .inProgress:
            return userData.history.filter { !userData.isWatched($0) }
        case .completed:
            return userData.history.filter { userData.isWatched($0) }
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Header with Badge, Filters & Clear Action
                VStack(alignment: .leading, spacing: 20) {
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
                        
                        if !userData.history.isEmpty {
                            Button(role: .destructive) {
                                showClearConfirm = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12, weight: .bold))
                                    Text("Clear")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                .foregroundStyle(.white.opacity(0.75))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color.white.opacity(0.06)))
                                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    if !userData.history.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Filter.allCases, id: \.self) { filter in
                                let count: Int = {
                                    switch filter {
                                    case .all: return userData.history.count
                                    case .inProgress: return userData.history.filter { !userData.isWatched($0) }.count
                                    case .completed: return userData.history.filter { userData.isWatched($0) }.count
                                    }
                                }()
                                
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                        activeFilter = filter
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(filter.rawValue)
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
                }
                .padding(.top, 48)
                
                if userData.history.isEmpty {
                    LibraryEmptyState(
                        icon: "clock.arrow.circlepath",
                        title: showAsContinueWatching ? "No In-Progress Titles" : "No Watch History",
                        message: "Movies and TV shows you start watching will automatically appear here."
                    )
                } else if filteredItems.isEmpty {
                    VStack(spacing: 12) {
                        Text("No \(activeFilter.rawValue.lowercased()) titles in your history")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                        Button("Show All History") {
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
        .alert("Clear Watch History?", isPresented: $showClearConfirm) {
            Button("Clear All", role: .destructive) {
                for item in userData.history {
                    userData.removeFromHistory(item)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all titles from your recently watched history.")
        }
    }
}

#Preview {
    HistoryView()
}
