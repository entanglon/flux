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
                    VStack(spacing: 20) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.cyan, .blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 72, height: 72)
                            .glassEffect(.clear, in: .circle)
                        
                        Text("Your Watchlist is Empty")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        
                        Text("Save movies and TV shows to keep track of what you want to watch next.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                        
                        Button(action: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                selectedTab = .home
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Find Something to Watch")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                    .padding(.vertical, 60)
                    .padding(.horizontal, 40)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.clear, in: .rect(cornerRadius: 24))
                    .padding(.top, 20)
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
