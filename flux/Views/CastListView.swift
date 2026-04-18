import SwiftUI

struct CastListView: View {
    let cast: [CastMember]
    
    let columns = [
        GridItem(.adaptive(minimum: 120), spacing: 24)
    ]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 40) {
                ForEach(cast) { member in
                    VStack(spacing: 12) {
                        AsyncImage(url: member.imageURL) { img in
                            img.resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.gray
                        }
                        .frame(width: 120, height: 120)
                        .clipShape(Circle())
                        .glassEffect(.regular, in: .circle)
                        .shadow(radius: 5)
                        
                        VStack(spacing: 4) {
                            Text(member.name)
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                            
                            Text(member.role ?? "")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
            .padding(40)
        }
        .background(Color.black.opacity(0.9))
        .navigationTitle("Cast & Crew")
    }
}
