import SwiftUI

// MARK: - Collections Hub (sidebar Library section)

struct CollectionsView: View {
    @ObservedObject private var userData = UserDataService.shared
    @Binding var selectedTab: SidebarItem

    @State private var showCreateAlert = false
    @State private var newCollectionName = ""

    var body: some View {
        Group {
            if userData.collections.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    LibraryPageHeader(
                        title: "Collections",
                        rightAction: {
                            Button(action: { showCreateAlert = true }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("New List")
                                        .font(.system(size: 14, weight: .bold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 11)
                                .glassEffect(.regular.interactive(), in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    )

                    Spacer()

                    emptyState

                    Spacer()
                }
                .padding(.leading, LibraryScheme.leadingPadding)
                .padding(.trailing, LibraryScheme.trailingPadding)
                .padding(.top, LibraryScheme.topPadding)
                .padding(.bottom, LibraryScheme.bottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: LibraryScheme.headerBottomSpacing) {
                        LibraryPageHeader(
                            title: "Collections",
                            itemCount: userData.collections.count,
                            itemLabel: "LISTS",
                            rightAction: {
                                Button(action: { showCreateAlert = true }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 13, weight: .bold))
                                        Text("New List")
                                            .font(.system(size: 14, weight: .bold))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 11)
                                    .glassEffect(.regular.interactive(), in: .capsule)
                                }
                                .buttonStyle(.plain)
                            }
                        )

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 40) {
                            Button(action: { showCreateAlert = true }) {
                                newCollectionCard
                            }
                            .buttonStyle(.plain)

                            ForEach(userData.collections) { collection in
                                NavigationLink(value: CollectionNavigation(id: collection.id)) {
                                    CollectionCard(collection: collection,
                                                   onRename: { renameTarget = collection },
                                                   onDelete: { deleteCandidate = collection })
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Rename…") { renameTarget = collection }
                                    Button("Delete", role: .destructive) { deleteCandidate = collection }
                                }
                            }
                        }
                    }
                    .padding(.leading, LibraryScheme.leadingPadding)
                    .padding(.trailing, LibraryScheme.trailingPadding)
                    .padding(.top, LibraryScheme.topPadding)
                    .padding(.bottom, LibraryScheme.bottomPadding)
                }
            }
        }
        .background(Color.clear)
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .alert("New Collection", isPresented: $showCreateAlert) {
            TextField("List name", text: $newCollectionName)
            Button("Create") {
                userData.createCollection(name: newCollectionName)
                newCollectionName = ""
            }
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        } message: {
            Text("Group movies and shows into your own lists.")
        }
        .alert("Rename Collection", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("List name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    userData.renameCollection(id: target.id, to: renameText)
                }
                renameTarget = nil
                renameText = ""
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text(renameTarget.map { "Rename \"\($0.name)\"." } ?? "")
        }
        .alert("Delete Collection?", isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let candidate = deleteCandidate {
                    userData.deleteCollection(id: candidate.id)
                }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text(deleteCandidate.map { "\"\($0.name)\" will be removed. Titles inside are not deleted from Flux." } ?? "")
        }
    }

    @State private var renameTarget: UserCollection?
    @State private var renameText: String = ""
    @State private var deleteCandidate: UserCollection?

    // MARK: Empty state

    private var emptyState: some View {
        LibraryEmptyState(
            icon: "rectangle.stack.fill",
            title: "No Collections Yet",
            message: "Create custom lists to organize your movies and shows any way you like.",
            actionTitle: "Create Your First List",
            actionIcon: "plus",
            action: { showCreateAlert = true }
        )
    }

    /// Dashed "+ New" tile that leads the grid.
    private var newCollectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.white.opacity(0.08)))

                Text("New List")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 160, height: 240)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .contentShape(Rectangle())

            // Align baseline with CollectionCard's 2-line title and subtitle
            Text(" ")
                .font(.system(size: 14, weight: .semibold))
            Text(" ")
                .font(.system(size: 11, weight: .medium))
        }
    }
}

// MARK: - Collection Card (poster stack preview + hover actions)

private struct CollectionCard: View {
    let collection: UserCollection
    var onRename: () -> Void = {}
    var onDelete: () -> Void = {}
    @State private var isHovered = false
    @State private var previewURLs: [URL] = []

    private var strokeGradient: LinearGradient {
        LinearGradient(
            colors: isHovered
                ? [Color.white.opacity(0.70), Color.white.opacity(0.20), Color.blue.opacity(0.15)]
                : [Color.white.opacity(0.18), Color.white.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            posterStack
                .frame(width: 160, height: 240)
                .overlay(alignment: .topTrailing) {
                    if isHovered {
                        HStack(spacing: 6) {
                            hoverAction(icon: "pencil", action: onRename)
                            hoverAction(icon: "trash", action: onDelete)
                        }
                        .padding(8)
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !collection.items.isEmpty {
                        Text("\(collection.items.count)")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.9)))
                            .padding(8)
                    }
                }

            Text(collection.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(collection.items.isEmpty
                 ? "Empty list"
                 : "\(collection.items.count) \(collection.items.count == 1 ? "title" : "titles")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) { isHovered = hovering }
        }
        .onAppear { loadPreviewURLs() }
        .onChange(of: collection.items) { _, _ in loadPreviewURLs() }
        .task(id: collection.id) {
            var resolved: [URL] = []
            for item in collection.items.prefix(3) {
                if let u = item.posterURL ?? item.imageURL ?? item.backdropURL {
                    resolved.append(u)
                } else {
                    let enriched = await TMDBEnricher.shared.quickEnrich(item)
                    if let u = enriched.posterURL ?? enriched.imageURL ?? enriched.backdropURL {
                        resolved.append(u)
                    }
                }
            }
            if !resolved.isEmpty {
                await MainActor.run {
                    self.previewURLs = resolved
                }
            }
        }
    }

    private func loadPreviewURLs() {
        let urls = collection.previewPosters.compactMap { $0 }
        self.previewURLs = urls
    }

    @ViewBuilder
    private var posterStack: some View {
        if collection.items.isEmpty {
            // Empty placeholder card
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                    
                    Text("Empty")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.40))
                }
            }
            .frame(width: 160, height: 240)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.30 : 0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.20), radius: 6, y: 3)
        } else if collection.items.count == 1 {
            // Single poster card
            ZStack {
                singlePoster(url: previewURLs.first, width: 160, height: 240, cornerRadius: 16)

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(strokeGradient, lineWidth: isHovered ? 1.5 : 0.75)
            }
            .frame(width: 160, height: 240)
            .shadow(color: .black.opacity(isHovered ? 0.45 : 0.25), radius: isHovered ? 14 : 7, y: isHovered ? 8 : 4)
        } else {
            // Stacked cards for multiple items (2 or 3+ items)
            ZStack {
                // Card 3 (back-most, only if count >= 3)
                if collection.items.count >= 3 {
                    ZStack {
                        singlePoster(url: previewURLs.count > 2 ? previewURLs[2] : nil, width: 154, height: 232, cornerRadius: 14)

                        Color.black.opacity(0.30)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .frame(width: 154, height: 232)
                    .rotationEffect(.degrees(isHovered ? -5.5 : -3.5))
                    .offset(x: isHovered ? -10 : -6, y: isHovered ? -6 : -4)
                    .shadow(color: .black.opacity(0.30), radius: 6, y: 3)
                }

                // Card 2 (middle card)
                ZStack {
                    singlePoster(url: previewURLs.count > 1 ? previewURLs[1] : nil, width: 156, height: 236, cornerRadius: 15)

                    Color.black.opacity(0.16)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                }
                .frame(width: 156, height: 236)
                .rotationEffect(.degrees(isHovered ? 5.5 : 3.5))
                .offset(x: isHovered ? 10 : 6, y: isHovered ? -4 : -2)
                .shadow(color: .black.opacity(0.38), radius: 8, y: 4)

                // Card 1 (front card)
                ZStack {
                    singlePoster(url: previewURLs.first, width: 160, height: 240, cornerRadius: 16)

                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(strokeGradient, lineWidth: isHovered ? 1.5 : 0.75)
                }
                .frame(width: 160, height: 240)
                .shadow(color: .black.opacity(isHovered ? 0.50 : 0.28), radius: isHovered ? 14 : 7, y: isHovered ? 8 : 4)
            }
            .frame(width: 160, height: 240)
        }
    }

    private func singlePoster(url: URL?, width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.12))

            if let url = url {
                CachedImage(url: url, maxDimension: 480) { phase in
                    if let img = phase.image {
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width, height: height)
                            .clipped()
                    } else {
                        Rectangle().fill(Color.white.opacity(0.06))
                    }
                }
            } else {
                Image(systemName: "film")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.30))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func hoverAction(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.black.opacity(0.65)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Collection Detail (member grid)

struct CollectionDetailView: View {
    let collectionID: String
    @ObservedObject private var userData = UserDataService.shared
    @State private var showRenameAlert = false
    @State private var showDeleteConfirm = false
    @State private var renameText = ""
    @Environment(\.dismiss) private var dismiss

    private var collection: UserCollection? {
        userData.collections.first(where: { $0.id == collectionID })
    }

    var body: some View {
        Group {
            if let collection, collection.items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    LibraryPageHeader(
                        title: collection.name,
                        rightAction: {
                            HStack(spacing: 10) {
                                Button(action: {
                                    renameText = collection.name
                                    showRenameAlert = true
                                }) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 34, height: 34)
                                        .glassEffect(.regular.interactive(), in: .circle)
                                }
                                .buttonStyle(.plain)
                                .help("Rename")

                                Button(action: { showDeleteConfirm = true }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.red.opacity(0.9))
                                        .frame(width: 34, height: 34)
                                        .glassEffect(.regular.interactive(), in: .circle)
                                }
                                .buttonStyle(.plain)
                                .help("Delete list")
                            }
                        }
                    )

                    Spacer()

                    memberEmptyState(name: collection.name)

                    Spacer()
                }
                .padding(.leading, LibraryScheme.leadingPadding)
                .padding(.trailing, LibraryScheme.trailingPadding)
                .padding(.top, LibraryScheme.topPadding)
                .padding(.bottom, LibraryScheme.bottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let collection {
                ScrollView {
                    VStack(alignment: .leading, spacing: LibraryScheme.headerBottomSpacing) {
                        LibraryPageHeader(
                            title: collection.name,
                            itemCount: collection.items.count,
                            itemLabel: "TITLES",
                            rightAction: {
                                HStack(spacing: 10) {
                                    Button(action: {
                                        renameText = collection.name
                                        showRenameAlert = true
                                    }) {
                                        Image(systemName: "pencil")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 34, height: 34)
                                            .glassEffect(.regular.interactive(), in: .circle)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Rename")

                                    Button(action: { showDeleteConfirm = true }) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.red.opacity(0.9))
                                            .frame(width: 34, height: 34)
                                            .glassEffect(.regular.interactive(), in: .circle)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete list")
                                }
                            }
                        )

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 40) {
                            ForEach(collection.items) { item in
                                ZStack(alignment: .topTrailing) {
                                    NavigationLink(value: item) {
                                        GlassCard(item: item, aspectRatio: .portrait)
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        userData.removeFromCollection(collectionID: collectionID, item: item)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .heavy))
                                            .foregroundStyle(.white)
                                            .frame(width: 22, height: 22)
                                            .background(Circle().fill(Color.black.opacity(0.75)))
                                            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(8)
                                    .help("Remove from list")
                                }
                            }
                        }
                    }
                    .padding(.leading, LibraryScheme.leadingPadding)
                    .padding(.trailing, LibraryScheme.trailingPadding)
                    .padding(.top, LibraryScheme.topPadding)
                    .padding(.bottom, LibraryScheme.bottomPadding)
                }
            }
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
        .background(Color.clear)
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .alert("Rename Collection", isPresented: $showRenameAlert) {
            TextField("List name", text: $renameText)
            Button("Rename") { userData.renameCollection(id: collectionID, to: renameText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(collection.map { "Rename \"\($0.name)\"." } ?? "")
        }
        .alert("Delete Collection?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                userData.deleteCollection(id: collectionID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(collection.map { "\"\($0.name)\" will be removed. Titles inside are not deleted from Flux." } ?? "")
        }
    }

    private func memberEmptyState(name: String) -> some View {
        LibraryEmptyState(
            icon: "square.stack.3d.up",
            title: "\"\(name)\" is Empty",
            message: "Open any movie or show and use the list button to add it here."
        )
    }
}

// MARK: - Add-to-Collection popover (DetailView)

/// Popover listing every user collection with live checkmarks plus an inline
/// create field — the Stremio-style "add to my lists" affordance.
struct AddToCollectionView: View {
    let item: MediaItem
    @ObservedObject private var userData = UserDataService.shared
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("New list name", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .onSubmit(createAndAdd)
                Button(action: createAndAdd) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(newName.trimmingCharacters(in: .whitespaces).isEmpty ? Color.white.opacity(0.25) : .white.opacity(0.95))
                }
                .buttonStyle(.plain)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().background(Color.white.opacity(0.12))

            if userData.collections.isEmpty {
                Text("No lists yet — name one above.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(userData.collections) { collection in
                            let member = userData.isInCollection(collectionID: collection.id, item: item)
                            Button(action: {
                                userData.toggleCollectionMembership(collectionID: collection.id, item: item)
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: member ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(member ? Color.white.opacity(0.95) : Color.white.opacity(0.35))

                                    Text(collection.name)
                                        .font(.system(size: 13, weight: member ? .bold : .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Spacer()
                                    Text("\(collection.items.count)")
                                        .font(.system(size: 10, weight: .heavy))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(member ? Color.white.opacity(0.07) : Color.clear)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 220)
            }
        }
        .frame(width: 240)
        .padding(.vertical, 6)
    }

    private func createAndAdd() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let collection = userData.createCollection(name: trimmed)
        userData.toggleCollectionMembership(collectionID: collection.id, item: item)
        newName = ""
    }
}
