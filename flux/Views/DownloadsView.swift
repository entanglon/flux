import SwiftUI

struct DownloadsView: View {
    let downloadItems: [MediaItem] = []
    
    let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 24)
    ]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Header
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Downloads")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(.white)
                    
                    if !downloadItems.isEmpty {
                        Text("\(downloadItems.count) ITEMS")
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
                
                if downloadItems.isEmpty {
                    // Apple TV Liquid Glass Empty State Card
                    VStack(spacing: 20) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.teal, .cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 72, height: 72)
                            .glassEffect(.clear, in: .circle)
                        
                        Text("No Downloads Available")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        
                        Text("Downloaded movies and TV episodes will be saved here for offline playback.")
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
                        ForEach(downloadItems) { item in
                            NavigationLink(value: item) {
                                GlassCard(item: item, aspectRatio: .portrait)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.cyan)
                                            .padding(10)
                                    }
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
    DownloadsView()
}
