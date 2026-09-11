import SwiftUI

/// Full-screen gate: profile selection + creation, styled with the app's
/// glassmorphism theme (dark mesh gradient, glass panels, capsule buttons).
struct ProfileGateView: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @ObservedObject private var languageManager = LanguageManager.shared
    @State private var isCreating = false
    @State private var isManaging = false
    @State private var editingProfile: UserProfile? = nil
    @State private var deletingProfile: UserProfile? = nil
    @State private var pendingProfileToEnter: UserProfile? = nil
    @State private var showingEnterPinSheet = false
    @State private var showingKidsFirstTimeSetupSheet = false

    var body: some View {
        ZStack {
            // Same mesh background as the main app
            Color.black
            .ignoresSafeArea()

            if isCreating || editingProfile != nil || profileManager.isFirstRun {
                if let editing = editingProfile {
                    ProfileCreationView(
                        title: "Edit Profile".localized,
                        profileId: editing.id,
                        initialName: editing.displayName,
                        initialAvatarID: editing.avatarID,
                        isKids: editing.isKids,
                        onCreate: { _, _ in },
                        onUpdate: { name, avatar in
                            profileManager.updateProfile(editing, name: name, avatarID: avatar)
                            editingProfile = nil
                        },
                        onCancel: { editingProfile = nil }
                    )
                } else {
                    ProfileCreationView(
                        title: profileManager.isFirstRun ? "Create Your Profile".localized : "Add a Profile".localized,
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
        .sheet(isPresented: $showingKidsFirstTimeSetupSheet) {
            if let kidsProfile = pendingProfileToEnter {
                PINEntrySheet(mode: .setup(
                    title: "Protect Kids Profile".localized,
                    subtitle: "Create a 4-digit PIN required to exit Kids mode".localized,
                    profileId: kidsProfile.id,
                    onSuccess: { _ in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            profileManager.selectProfile(kidsProfile)
                        }
                        pendingProfileToEnter = nil
                    }
                ))
            }
        }
        .sheet(isPresented: $showingEnterPinSheet) {
            if let profile = pendingProfileToEnter {
                PINEntrySheet(mode: .verify(
                    title: profile.displayName,
                    subtitle: String.localizedFormat("Enter 4-digit PIN to access %@", profile.displayName),
                    profileId: profile.id,
                    onSuccess: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            profileManager.selectProfile(profile)
                        }
                        pendingProfileToEnter = nil
                    }
                ))
            }
        }
        .alert(String.localizedFormat("Delete \"%@\"?", deletingProfile?.displayName ?? ""), isPresented: Binding(
            get: { deletingProfile != nil },
            set: { if !$0 { deletingProfile = nil } }
        )) {
            Button("Delete".localized, role: .destructive) {
                if let p = deletingProfile { profileManager.deleteProfile(p) }
                deletingProfile = nil
                if profileManager.profiles.isEmpty { isManaging = false }
            }
            Button("Cancel".localized, role: .cancel) { deletingProfile = nil }
        } message: {
            Text("This profile's watch history, watchlist, and recommendations will be removed.".localized)
        }
    }

    private var selectionView: some View {
        VStack(spacing: 40) {
            Spacer()

            VStack(spacing: 10) {
                Text("Who's Watching?".localized)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Pick a profile to jump back in".localized)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            HStack(spacing: 32) {
                ForEach(profileManager.profiles) { profile in
                    ManageableProfileTile(
                        profile: profile,
                        isManaging: isManaging,
                        onSelect: {
                            if profile.isKids {
                                if !ParentalLockManager.shared.hasPin(for: profile.id) && !ParentalLockManager.shared.hasPin() {
                                    pendingProfileToEnter = profile
                                    showingKidsFirstTimeSetupSheet = true
                                } else {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        profileManager.selectProfile(profile)
                                    }
                                }
                            } else if profileManager.requiresPinToEnter(profile: profile) {
                                pendingProfileToEnter = profile
                                showingEnterPinSheet = true
                            } else {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    profileManager.selectProfile(profile)
                                }
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
                    Text(isManaging ? "Done".localized : "Manage Profiles".localized)
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
                        if isManaging && !profile.isStock && !profile.isKids {
                            manageButton("xmark") { onDelete() }
                                .offset(x: 8, y: -8)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if ParentalLockManager.shared.hasPin(for: profile.id) && !isManaging {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(Circle().fill(Color.black.opacity(0.75)))
                                .offset(x: 4, y: 4)
                        }
                    }

                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isHovering && !isManaging ? .white : .white.opacity(0.6))

                    if profile.isKids {
                        Text("KIDS".localized)
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.yellow))
                    }
                }
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

                Text("Add Profile".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isHovering ? .white : .white.opacity(0.6))
            }
            .contentShape(Rectangle())
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
        Group {
            if avatarID.hasPrefix("avatar-cat-") || avatarID.hasPrefix("avatar-pet-") || NSImage(named: avatarID) != nil {
                Image(avatarID)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                AvatarFaceView(style: AvatarStyle.style(for: avatarID))
            }
        }
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
    var profileId: UUID? = nil
    var initialName: String? = nil
    var initialAvatarID: String? = nil
    var isKids: Bool = false
    let onCreate: (String, String) -> Void
    var onUpdate: ((String, String) -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    @State private var name = ""
    @State private var selectedAvatar = AvatarItem.all[0].id
    @State private var selectedCategory: AvatarItem.Category = .characters
    @State private var isHoveringCreate = false
    @State private var showingSetPin = false
    @ObservedObject private var lockManager = ParentalLockManager.shared
    @ObservedObject private var languageManager = LanguageManager.shared
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Glass panel
            VStack(spacing: 22) {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                // Name field — glass capsule, matches the app's search bar
                HStack(spacing: 10) {
                    Image(systemName: isKids ? "lock.fill" : "pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))

                    TextField("Profile name".localized, text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .focused($isNameFocused)
                        .disabled(isKids)

                    if !name.isEmpty && !isKids {
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
                .frame(width: 380, height: 46)
                .glassEffect(.regular.interactive(), in: .capsule)

                if isKids {
                    Text("Stock Kids profile cannot be renamed".localized)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .offset(y: -10)
                }

                // Category selector: Cats vs Faces
                HStack(spacing: 8) {
                    ForEach(AvatarItem.Category.allCases, id: \.self) { cat in
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                selectedCategory = cat
                            }
                        } label: {
                            Text(cat.localizedName)
                                .font(.system(size: 12, weight: selectedCategory == cat ? .bold : .medium))
                                .foregroundStyle(selectedCategory == cat ? .white : .white.opacity(0.6))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(selectedCategory == cat ? Color.white.opacity(0.18) : Color.white.opacity(0.04))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Avatar picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        let items = AvatarItem.all.filter { $0.category == selectedCategory }
                        ForEach(items) { item in
                            Button {
                                selectedAvatar = item.id
                            } label: {
                                AvatarBadge(avatarID: item.id, size: 70, isActive: selectedAvatar == item.id)
                                    .scaleEffect(selectedAvatar == item.id ? 1.08 : 1.0)
                                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selectedAvatar)
                            }
                            .buttonStyle(.plain)
                            .onHover { h in
                                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
                }
                .frame(width: 480)

                // PIN Protection Row (when editing profile)
                if let pid = profileId {
                    HStack(spacing: 12) {
                        Image(systemName: lockManager.hasPin(for: pid) ? "lock.fill" : "lock.open")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(lockManager.hasPin(for: pid) ? Color.yellow : Color.white.opacity(0.6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(isKids ? "Exit PIN Protection".localized : "Profile Lock (PIN)".localized)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(lockManager.hasPin(for: pid) ? "4-digit PIN is active".localized : (isKids ? "Kids can exit freely without PIN".localized : "Anyone can enter without PIN".localized))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.55))
                        }

                        Spacer()

                        if lockManager.hasPin(for: pid) {
                            Button("Change PIN".localized) { showingSetPin = true }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("Remove".localized) { lockManager.removePin(for: pid) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        } else {
                            Button(isKids ? "Set Exit PIN".localized : "Set PIN".localized) { showingSetPin = true }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .frame(width: 440)
                }

                // Create / Save — white capsule, matches the Play button
                Button {
                    if let onUpdate {
                        onUpdate(name, selectedAvatar)
                    } else {
                        onCreate(name, selectedAvatar)
                    }
                } label: {
                    Text(onUpdate != nil ? "Save Changes".localized : "Create Profile".localized)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canCreate ? .black : .white.opacity(0.4))
                        .padding(.horizontal, 48)
                        .padding(.vertical, 12)
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
                    Button("Cancel".localized) { onCancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .glassEffect(.regular, in: .rect(cornerRadius: 32))

            Spacer()
        }
        .sheet(isPresented: $showingSetPin) {
            if let pid = profileId {
                PINEntrySheet(mode: .setup(
                    title: isKids ? "Exit PIN Protection".localized : "Set Profile PIN".localized,
                    subtitle: isKids ? "Enter 4-digit PIN required to exit Kids profile".localized : String.localizedFormat("Enter 4-digit PIN to lock %@", name.isEmpty ? "profile".localized : name),
                    profileId: pid
                ))
            }
        }
        .onAppear {
            if let initialName { name = initialName }
            if let initialAvatarID {
                selectedAvatar = initialAvatarID
                if let item = AvatarItem.all.first(where: { $0.id == initialAvatarID }) {
                    selectedCategory = item.category
                }
            }
            if !isKids { isNameFocused = true }
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
