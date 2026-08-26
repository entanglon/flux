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
                    NavigationLink(destination: PersonView(personID: member.personID ?? 0, fallbackName: member.name)) {
                        VStack(spacing: 12) {
                            CastCircle(name: member.name, imageURL: member.imageURL, size: 120)

                            VStack(spacing: 4) {
                                Text(member.name)
                                    .font(.headline)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(1)

                                Text(member.role ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(1)
                            }
                            .frame(height: 52)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(member.personID == nil)
                }
            }
            .padding(40)
        }
        .background(Color.black.opacity(0.9))
        .navigationTitle("Cast & Crew")
    }
}
