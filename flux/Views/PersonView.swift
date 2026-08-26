import SwiftUI

/// Person page — hero (photo + name + facts), biography, filmography grid.
struct PersonView: View {
    let personID: Int
    let fallbackName: String

    @State private var details: TMDBPersonDetail?
    @State private var credits: [MediaItem] = []
    @State private var isLoading = true
    @State private var bioExpanded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection

                if isLoading {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 40) {
                        ForEach(0..<12, id: \.self) { _ in
                            GhostCard()
                        }
                    }
                    .padding(.leading, 268)
                    .padding(.trailing, 40)
                    .padding(.top, 40)
                    .padding(.bottom, 60)
                } else {
                    biographySection
                    filmographySection
                }
            }
            .padding(.bottom, 80)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarBackButtonHidden(true)
        .overlay(alignment: .topLeading) {
            // Back button — same glass circle as other pages
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
        .background(
            Color.black
            .ignoresSafeArea()
        )
        .task {
            async let d: TMDBPersonDetail? = TMDBEnricher.shared.fetchPerson(personID: personID)
            async let c: [MediaItem] = TMDBEnricher.shared.fetchPersonCredits(personID: personID)
            let (detailsRes, creditsRes) = await (d, c)
            self.details = detailsRes
            self.credits = creditsRes.filter { $0.isReleased }
            self.isLoading = false
        }
    }

    private var displayName: String {
        details?.name ?? fallbackName
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            // Backdrop: blurred profile or mesh gradient
            ZStack {
                if let url = details?.profileURL {
                    CachedImage(url: url, maxDimension: 800) { phase in
                        if let img = phase.image {
                            img.resizable()
                                .aspectRatio(contentMode: .fill)
                                .blur(radius: 40)
                                .overlay(Color.black.opacity(0.55))
                        } else {
                            Color.black
                        }
                    }
                } else {
                    Color.black
                }
            }
            .frame(height: 380)
            .frame(maxWidth: .infinity)
            .clipped()

            // Content: photo + identity
            HStack(alignment: .bottom, spacing: 28) {
                CachedImage(url: details?.profileURL, maxDimension: 500) { phase in
                    if let img = phase.image {
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Rectangle().fill(Color.white.opacity(0.08))
                            Text(String(displayName.prefix(1)))
                                .font(.system(size: 44, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .frame(width: 190, height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)

                VStack(alignment: .leading, spacing: 10) {
                    Text(displayName)
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    if let dept = details?.knownForDepartment, !dept.isEmpty {
                        Text("Known for \(dept)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    HStack(spacing: 18) {
                        if let bday = details?.birthday, !bday.isEmpty {
                            Label(formatDate(bday), systemImage: "calendar")
                        }
                        if let death = details?.deathday, !death.isEmpty {
                            Label("† \(formatDate(death))", systemImage: "sun.min")
                        }
                        if let place = details?.placeOfBirth, !place.isEmpty {
                            Label(String(place.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) ?? place), systemImage: "mappin.and.ellipse")
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()
            }
            .padding(.leading, 268)
            .padding(.trailing, 40)
            .padding(.bottom, 28)
        }
    }

    // MARK: - Biography

    @ViewBuilder
    private var biographySection: some View {
        if let bio = details?.biography, !bio.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Biography")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                Text(bio.replacingOccurrences(of: "\n\n\n", with: "\n\n"))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineSpacing(5)
                    .lineLimit(bioExpanded ? nil : 5)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { bioExpanded.toggle() }
                } label: {
                    Text(bioExpanded ? "Show Less" : "Read More")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 268)
            .padding(.trailing, 40)
            .padding(.top, 36)
        }
    }

    // MARK: - Filmography

    @ViewBuilder
    private var filmographySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Movies & Shows")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                if !credits.isEmpty {
                    Text("\(credits.count) CREDITS")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassEffect(.clear, in: .capsule)
                }
            }

            if credits.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No credits found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 40) {
                    ForEach(credits) { item in
                        NavigationLink(destination: DetailView(item: item)) {
                            GlassCard(item: item, aspectRatio: .portrait, showTitle: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.leading, 268)
        .padding(.trailing, 40)
        .padding(.top, 40)
    }

    private func formatDate(_ iso: String) -> String {
        let inFmt = DateFormatter()
        inFmt.dateFormat = "yyyy-MM-dd"
        guard let date = inFmt.date(from: iso) else { return iso }
        let outFmt = DateFormatter()
        outFmt.dateFormat = "MMM d, yyyy"
        return outFmt.string(from: date)
    }
}
