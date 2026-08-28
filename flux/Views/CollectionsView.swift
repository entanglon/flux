import SwiftUI

// MARK: - Collections Hub (sidebar Library section)

struct CollectionsView: View {
    @ObservedObject private var userData = UserDataService.shared
    @Binding var selectedTab: SidebarItem

    @State private var showCreateAlert = false
    @State private var newCollectionName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Collections")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(.white)

                    if !userData.collections.isEmpty {
                        Text("\(userData.collections.count) LISTS")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .glassEffect(.clear, in: .capsule)
                    }

                    Spacer()

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
                .padding(.top, 48)

                if userData.collections.isEmpty {
                    emptyState
                } else {
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
            }
            .padding(.leading, 268)
            .padding(.trailing, 40)
            .padding(.top, 40)
            .padding(.bottom, 60)
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
        VStack(spacing: 14) {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.white.opacity(0.08)))

            Text("New List")
                .font(.system(size: 14, weight: .bold))
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
    }
}

// MARK: - Collection Card (poster stack preview + hover actions)

private struct CollectionCard: View {
    let collection: UserCollection
    var onRename: () -> Void = {}
    var onDelete: () -> Void = {}
    @State private var isHovered = false

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
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(collection.items.count)")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.9)))
                        .padding(8)
                        .opacity(collection.items.isEmpty ? 0 : 1)
                }

            Text(collection.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(collection.items.isEmpty
                 ? "Empty list"
                 : "\(collection.items.count) \(collection.items.count == 1 ? "title" : "titles")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) { isHovered = hovering }
        }
    }

    // Poster stack: up to three members fanned behind the newest one.
    private var posterStack: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))

            let posters = collection.previewPosters.compactMap { $0 }
            ForEach(Array(posters.dropFirst().enumerated().reversed()), id: \.offset) { index, url in
                stackPoster(url: url)
                    .rotationEffect(.degrees(index == 0 ? -5 : 4))
                    .offset(x: index == 0 ? -10 : 9, y: index == 0 ? -2 : 3)
            }

            if let front = posters.first {
                stackPoster(url: front)
                    .rotationEffect(.degrees(-1))
            } else {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(isHovered ? 0.35 : 0.12), lineWidth: 1)
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .shadow(color: .black.opacity(0.45), radius: isHovered ? 16 : 8, y: 6)
    }

    private func stackPoster(url: URL) -> some View {
        CachedImage(url: url, maxDimension: 600) { phase in
            if let img = phase.image {
                img.resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
            }
        }
        .frame(width: 132, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.35), lineWidth: 2)
        )
    }

    private func hoverAction(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.black.opacity(0.65)))
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
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if let collection {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(collection.name)
                            .font(.system(size: 44, weight: .heavy))
                            .foregroundStyle(.white)

                        if !collection.items.isEmpty {
                            Text("\(collection.items.count) TITLES")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .glassEffect(.clear, in: .capsule)
                        }

                        Spacer()

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
                    .padding(.top, 48)

                    if collection.items.isEmpty {
                        memberEmptyState(name: collection.name)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 40) {
                            ForEach(collection.items) { item in
                                GlassCard(item: item, aspectRatio: .portrait)
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            userData.removeFromCollection(collectionID: collectionID, item: item)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 9, weight: .heavy))
                                                .foregroundStyle(.white)
                                                .frame(width: 22, height: 22)
                                                .background(Circle().fill(Color.black.opacity(0.7)))
                                                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                        .padding(8)
                                        .help("Remove from list")
                                    }
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
