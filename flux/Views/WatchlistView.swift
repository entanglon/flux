import SwiftUI

struct WatchlistView: View {
    @ObservedObject var userData = UserDataService.shared
    @Binding var selectedTab: SidebarItem
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Apple TV Header with Item Count Badge
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Watchlist")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(.white)
                    
                    if !userData.watchlist.isEmpty {
                        Text("\(userData.watchlist.count) ITEMS")
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
                
                if userData.watchlist.isEmpty {
                    // Apple TV Liquid Glass Empty State Card
                    LibraryEmptyState(
                        icon: "bookmark.fill",
                        title: "Your Watchlist is Empty",
                        message: "Save movies and TV shows to keep track of what you want to watch next.",
                        actionTitle: "Find Something to Watch",
                        actionIcon: "sparkles",
                        action: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                selectedTab = .home
                            }
                        }
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 40) {
                        ForEach(userData.watchlist) { item in
                            NavigationLink(value: item) {
                                GlassCard(item: item, aspectRatio: .portrait)
                            }
                            .buttonStyle(.plain)
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
    WatchlistView(selectedTab: .constant(.watchlist))
}
