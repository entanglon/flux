import SwiftUI

struct CastListView: View {
    let cast: [CastMember]

    let columns = [
        GridItem(.adaptive(minimum: 120), spacing: 24)
    ]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Header
                HStack(spacing: 16) {
                    Text("Cast & Crew")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(.white)

                    Spacer()
                }
                .padding(.top, 48)

                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(cast) { member in
                        NavigationLink(value: PersonNavigation(id: member.personID ?? 0, fallbackName: member.name)) {
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
            }
            .padding(.leading, 268)
            .padding(.trailing, 40)
            .padding(.top, 40)
            .padding(.bottom, 40)
        }
        .overlay(alignment: .topLeading) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .padding(.leading, 268)
            .padding(.top, 24)
        }
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .background(Color.black)
    }
}
