import SwiftUI

/// Shared email/password form used by both the first-start gate (full page)
/// and the Settings sign-in sheet (card).
struct AuthFormView: View {
    var startInSignUp: Bool = false
    var showsGuestOption: Bool = false
    var showsTitle: Bool = true
    var isModal: Bool = false
    var onCancel: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var authManager = AuthManager.shared
    @State private var isSignUp: Bool
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var ctaHovered = false
    @State private var showPassword = false
    @State private var showConfirmPassword = false
    @FocusState private var focusedField: FieldID?

    private enum FieldID: Hashable {
        case name, email, password, confirm
    }

    init(startInSignUp: Bool = false,
         showsGuestOption: Bool = false,
         showsTitle: Bool = true,
         isModal: Bool = false,
         onCancel: (() -> Void)? = nil) {
        self.startInSignUp = startInSignUp
        self.showsGuestOption = showsGuestOption
        self.showsTitle = showsTitle
        self.isModal = isModal
        self.onCancel = onCancel
        _isSignUp = State(initialValue: startInSignUp)
    }

    private var busy: Bool { isLoading || authManager.isLoading }

    var body: some View {
        VStack(spacing: 14) {
            if showsTitle {
                VStack(spacing: 6) {
                    Text(isSignUp ? "Create your account" : "Sign in to Flux")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    Text(isSignUp
                         ? "Sync your library across every Mac."
                         : "Enter your credentials to continue.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.bottom, 12)
            }

            fieldsSection
            errorBlock
            ctaButton
            switchModeButton

            if showsGuestOption {
                Button(action: { authManager.continueAsGuest() }) {
                    Text("Continue as Guest")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Guests stay on this Mac only — nothing syncs.")
            }

            if let onCancel {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: authManager.currentUser) { _, user in
            if user != nil && isModal {
                dismiss()
                onCancel?()
            }
        }
        .onChange(of: authManager.errorMessage) { _, error in
            if let error {
                self.errorMessage = error
                self.isLoading = false
            }
        }
        .onChange(of: authManager.isLoading) { _, loading in
            self.isLoading = loading
        }
    }

    // MARK: - Sections

    private var fieldsSection: some View {
        VStack(spacing: 10) {
            if isSignUp {
                fieldRow(icon: "person", text: $name, focusID: .name) {
                    TextField("Your Name", text: $name)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .name)
                }
            }

            fieldRow(icon: "envelope", text: $email, focusID: .email) {
                TextField("Email", text: $email)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
            }

            if !email.isEmpty && !isValidEmail(email.trimmingCharacters(in: .whitespacesAndNewlines)) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                    Text("Enter a valid email address").font(.system(size: 11))
                }
                .foregroundStyle(.orange.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
            }

            fieldRow(icon: "lock", text: $password, focusID: .password, showsToggle: true, isSecure: !showPassword, toggleAction: { showPassword.toggle() }) {
                if showPassword {
                    TextField("Password", text: $password)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .password)
                } else {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .password)
                }
            }

            if isSignUp {
                fieldRow(icon: "lock", text: $confirmPassword, focusID: .confirm, showsToggle: true, isSecure: !showConfirmPassword, toggleAction: { showConfirmPassword.toggle() }) {
                    if showConfirmPassword {
                        TextField("Confirm Password", text: $confirmPassword)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .confirm)
                    } else {
                        SecureField("Confirm Password", text: $confirmPassword)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .confirm)
                    }
                }

                if !password.isEmpty && !confirmPassword.isEmpty && password != confirmPassword {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                        Text("Passwords don't match").font(.system(size: 11))
                    }
                    .foregroundStyle(.orange.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                }

                if !password.isEmpty && password.count < 8 {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle").font(.system(size: 10))
                        Text("Minimum 8 characters").font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var errorBlock: some View {
        if let error = errorMessage {
            Text(error)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.red.opacity(0.9))
                .multilineTextAlignment(.center)
        }
    }

    private var ctaButton: some View {
        Button(action: handleAuth) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(.black)
                }
                Text(isSignUp ? "Create Account" : "Sign In")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.white)
            .clipShape(Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(ctaHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: ctaHovered)
        .onHover { hovering in
            ctaHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .disabled(busy || email.isEmpty || !isValidEmail(email.trimmingCharacters(in: .whitespacesAndNewlines)) || password.isEmpty || (isSignUp && (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || confirmPassword.isEmpty || password != confirmPassword || password.count < 8)))
        .opacity((busy || email.isEmpty || !isValidEmail(email.trimmingCharacters(in: .whitespacesAndNewlines)) || password.isEmpty || (isSignUp && (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || confirmPassword.isEmpty || password != confirmPassword || password.count < 8))) ? 0.55 : 1)
    }

    private var switchModeButton: some View {
        Button(action: toggleMode) {
            Text(isSignUp ? "Already have an account? Sign In"
                          : "New here? Create an account")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fieldRow<Content: View>(
        icon: String,
        text: Binding<String>,
        focusID: FieldID,
        showsToggle: Bool = false,
        isSecure: Bool = false,
        toggleAction: (() -> Void)? = nil,
        @ViewBuilder field: () -> Content
    ) -> some View {
        ZStack(alignment: .leading) {
            // Background
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

            // Content
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 16, alignment: .center)

                field()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                if showsToggle, let toggleAction {
                    Button(action: toggleAction) {
                        Image(systemName: isSecure ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }

                if !text.wrappedValue.isEmpty {
                    Button(action: { text.wrappedValue = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = focusID
        }
    }

    private func toggleMode() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isSignUp.toggle()
            errorMessage = nil
            name = ""
            confirmPassword = ""
            showPassword = false
            showConfirmPassword = false
        }
    }

    private func handleAuth() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEmail(trimmedEmail) else {
            errorMessage = "Please enter a valid email address."
            return
        }
        email = trimmedEmail

        if isSignUp && password != confirmPassword {
            errorMessage = "Passwords don't match"
            return
        }

        if isSignUp && password.count < 8 {
            errorMessage = "Password must be at least 8 characters."
            return
        }

        isLoading = true
        errorMessage = nil

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            let success: Bool
            if isSignUp {
                success = await AuthManager.shared.signUp(
                    email: email,
                    password: password,
                    displayName: trimmedName.isEmpty ? nil : trimmedName
                )
            } else {
                success = await AuthManager.shared.signIn(email: email, password: password)
            }
            if success {
                await MainActor.run {
                    if isModal {
                        dismiss()
                        onCancel?()
                    }
                }
            }
        }
    }

    private func isValidEmail(_ value: String) -> Bool {
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
