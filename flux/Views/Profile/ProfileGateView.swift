import SwiftUI

/// Full-screen gate: profile selection + creation, styled with the app's
/// glassmorphism theme (dark mesh gradient, glass panels, capsule buttons).
struct ProfileGateView: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var isCreating = false
    @State private var isManaging = false
    @State private var editingProfile: UserProfile? = nil
    @State private var deletingProfile: UserProfile? = nil

    var body: some View {
        ZStack {
            // Same mesh background as the main app
            LinearGradient(
                gradient: Gradient(colors: [Color(#colorLiteral(red: 0.1, green: 0.1, blue: 0.2, alpha: 1)), .black]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if isCreating || editingProfile != nil || profileManager.isFirstRun {
                if let editing = editingProfile {
                    ProfileCreationView(
                        title: "Edit Profile",
                        initialName: editing.name,
                        initialAvatarID: editing.avatarID,
                        onCreate: { _, _ in },
                        onUpdate: { name, avatar in
                            profileManager.updateProfile(editing, name: name, avatarID: avatar)
                            editingProfile = nil
                        },
                        onCancel: { editingProfile = nil }
                    )
                } else {
                    ProfileCreationView(
                        title: profileManager.isFirstRun ? "Create Your Profile" : "Add a Profile",
                        onCreate: { name, avatar in
                            profileManager.createProfile(name: name, avatarID: avatar)
                            isCreating = false
                        },
                        onCancel: profileManager.isFirstRun ? nil : { isCreating = false }
                    )
                }
            } else {
                selectionView
            }
        }
        .alert("Delete \"\(deletingProfile?.name ?? "")\"?", isPresented: Binding(
            get: { deletingProfile != nil },
            set: { if !$0 { deletingProfile = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let p = deletingProfile { profileManager.deleteProfile(p) }
                deletingProfile = nil
                if profileManager.profiles.isEmpty { isManaging = false }
            }
            Button("Cancel", role: .cancel) { deletingProfile = nil }
        } message: {
            Text("This profile's watch history, watchlist, and recommendations will be removed.")
        }
    }

    private var selectionView: some View {
        VStack(spacing: 40) {
            Spacer()

            VStack(spacing: 10) {
                Text("Who's Watching?")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Pick a profile to jump back in")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            HStack(spacing: 32) {
                ForEach(profileManager.profiles) { profile in
                    ManageableProfileTile(
                        profile: profile,
                        isManaging: isManaging,
                        onSelect: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                profileManager.selectProfile(profile)
                            }
                        },
                        onEdit: { editingProfile = profile },
                        onDelete: { deletingProfile = profile }
                    )
                }

                if !isManaging {
                    AddProfileTile {
                        withAnimation(.easeInOut(duration: 0.2)) { isCreating = true }
                    }
                }
            }

            // Manage toggle — hidden on first run (need ≥1 profile before managing)
            if !profileManager.isFirstRun {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isManaging.toggle() }
                } label: {
                    Text(isManaging ? "Done" : "Manage Profiles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(isManaging ? 1 : 0.55))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(Color.white.opacity(isManaging ? 0.16 : 0.07))
                        )
                }
                .buttonStyle(.plain)
                .onHover { h in
                    if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }

            Spacer()
        }
    }
}

// MARK: - Manageable Tile (edit / delete overlays in manage mode)

struct ManageableProfileTile: View {
    let profile: UserProfile
    let isManaging: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: { if !isManaging { onSelect() } }) {
            VStack(spacing: 14) {
                AvatarBadge(avatarID: profile.avatarID, size: 112, isActive: isHovering)
                    .overlay {
                        if isManaging {
                            Color.black.opacity(0.45)
                                .clipShape(RoundedRectangle(cornerRadius: 112 * 0.18, style: .continuous))
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if isManaging {
                            manageButton("pencil") { onEdit() }
                                .offset(x: -8, y: -8)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isManaging {
                            manageButton("xmark") { onDelete() }
                                .offset(x: 8, y: -8)
                        }
                    }

                Text(profile.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isHovering && !isManaging ? .white : .white.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering && !isManaging ? 1.06 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private func manageButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white))
        }
        .buttonStyle(.plain)
    }
}

struct AddProfileTile: View {
    let onAdd: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onAdd) {
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(isHovering ? 0.7 : 0.25), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .frame(width: 112, height: 112)
                    .background(Color.white.opacity(isHovering ? 0.05 : 0.02))
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.white.opacity(isHovering ? 1 : 0.45))
                    }

                Text("Add Profile")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isHovering ? .white : .white.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.06 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Avatar Rendering (shared with sidebar footer)

struct AvatarBadge: View {
    let avatarID: String
    var size: CGFloat = 112
    var isActive: Bool = false

    var body: some View {
        AvatarFaceView(style: AvatarStyle.style(for: avatarID))
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                    .stroke(
                        isActive ? Color.white : Color.white.opacity(0.15),
                        lineWidth: isActive ? 3 : 1
                    )
            )
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }
}

// MARK: - Creation / Editing (glass panel, app theme)

struct ProfileCreationView: View {
    let title: String
    var initialName: String? = nil
    var initialAvatarID: String? = nil
    let onCreate: (String, String) -> Void
    var onUpdate: ((String, String) -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    @State private var name = ""
    @State private var selectedAvatar = AvatarStyle.all[0].id
    @State private var isHoveringCreate = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Glass panel
            VStack(spacing: 28) {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                // Name field — glass capsule, matches the app's search bar
                HStack(spacing: 10) {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))

                    TextField("Profile name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .focused($isNameFocused)

                    if !name.isEmpty {
                        Button {
                            name = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .frame(width: 360, height: 46)
                .glassEffect(.regular.interactive(), in: .capsule)

                // Pet avatar picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(AvatarStyle.all) { style in
                            Button {
                                selectedAvatar = style.id
                            } label: {
                                AvatarBadge(avatarID: style.id, size: 72, isActive: selectedAvatar == style.id)
                                    .scaleEffect(selectedAvatar == style.id ? 1.08 : 1.0)
                                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selectedAvatar)
                            }
                            .buttonStyle(.plain)
                            .onHover { h in
                                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
                .frame(width: 460)

                // Create / Save — white capsule, matches the Play button
                Button {
                    if let onUpdate {
                        onUpdate(name, selectedAvatar)
                    } else {
                        onCreate(name, selectedAvatar)
                    }
                } label: {
                    Text(onUpdate != nil ? "Save Changes" : "Create Profile")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(canCreate ? .black : .white.opacity(0.4))
                        .padding(.horizontal, 48)
                        .padding(.vertical, 14)
                        .background(
                            Capsule().fill(canCreate ? Color.white : Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
                .scaleEffect(isHoveringCreate && canCreate ? 1.04 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHoveringCreate)
                .onHover { h in isHoveringCreate = h }

                if let onCancel {
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .glassEffect(.regular, in: .rect(cornerRadius: 32))

            Spacer()
        }
        .onAppear {
            if let initialName { name = initialName }
            if let initialAvatarID { selectedAvatar = initialAvatarID }
            isNameFocused = true
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
