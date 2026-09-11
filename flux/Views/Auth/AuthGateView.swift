import SwiftUI

/// First-start identity gate: branding on left, inline email/password form on right.
/// No sheets — sign-in and sign-up live on this one screen.
struct AuthGateView: View {
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject private var languageManager = LanguageManager.shared
    @State private var isSignUp = false
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case email, password, displayName }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            HStack(spacing: 0) {
                // Left half — branding
                VStack(spacing: 20) {
                    Spacer()
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 128, height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.65), radius: 20, y: 10)

                    Text("Flux")
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundStyle(.white)

                    Text("Your movies, shows, and lists — everywhere.".localized)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Right half — form card
                ZStack {
                    Color.white.opacity(0.03)

                    VStack(spacing: 0) {
                        Spacer()

                        VStack(spacing: 24) {
                            // Title
                            Text((isSignUp ? "Create Account" : "Welcome Back").localized)
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)

                            // Fields
                            VStack(spacing: 14) {
                                if isSignUp {
                                    formField(icon: "person", placeholder: "Display name (optional)".localized, text: $displayName)
                                        .focused($focusedField, equals: .displayName)
                                }

                                formField(icon: "envelope", placeholder: "Email".localized, text: $email)
                                    .focused($focusedField, equals: .email)
                                    .textContentType(.emailAddress)
                                    .autocorrectionDisabled()

                                formField(icon: "lock", placeholder: "Password".localized, text: $password, isSecure: true)
                                    .focused($focusedField, equals: .password)
                                    .textContentType(isSignUp ? .newPassword : .password)
                            }

                            // Error
                            if let errorMessage {
                                Text(errorMessage.localized)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red.opacity(0.85))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 12)
                            }

                            // Submit
                            Button(action: submit) {
                                Group {
                                    if isLoading {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                    } else {
                                        Text((isSignUp ? "Create Account" : "Sign In").localized)
                                            .font(.system(size: 15, weight: .bold))
                                    }
                                }
                                .foregroundStyle(canSubmit ? .black : .white.opacity(0.4))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                            }
                            .buttonStyle(.plain)
                            .background(
                                Capsule().fill(canSubmit ? Color.white : Color.white.opacity(0.12))
                            )
                            .disabled(!canSubmit || isLoading)

                            // Toggle sign-in / sign-up
                            HStack(spacing: 4) {
                                Text((isSignUp ? "Already have an account?" : "New here?").localized)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.5))
                                Button(action: toggleMode) {
                                    Text((isSignUp ? "Sign In" : "Create Account").localized)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.9))
                                }
                                .buttonStyle(.plain)
                            }

                            Divider()
                                .background(Color.white.opacity(0.1))
                                .padding(.horizontal, 20)

                            Button(action: { authManager.continueAsGuest() }) {
                                Text("Continue as Guest".localized)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 36)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(44)
                        .frame(width: 420, height: 520, alignment: .center)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                )
                        )
                        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { focusedField = .email }
    }

    // MARK: - Helpers

    private func formField(icon: String, placeholder: String, text: Binding<String>, isSecure: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 16)

            if isSecure {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        !isLoading
    }

    private func toggleMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSignUp.toggle()
            errorMessage = nil
            password = ""
        }
        focusedField = isSignUp ? .displayName : .email
    }

    private func submit() {
        focusedField = nil
        guard canSubmit else { return }
        isLoading = true
        errorMessage = nil

        Task {
            let success: Bool
            if isSignUp {
                success = await authManager.signUp(
                    email: email.trimmingCharacters(in: .whitespaces),
                    password: password,
                    displayName: displayName.trimmingCharacters(in: .whitespaces)
                )
            } else {
                success = await authManager.signIn(
                    email: email.trimmingCharacters(in: .whitespaces),
                    password: password
                )
            }
            await MainActor.run {
                isLoading = false
                if !success {
                    errorMessage = authManager.errorMessage
                }
            }
        }
    }
}
