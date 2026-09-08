import SwiftUI

/// Email + password sign-in / sign-up form, styled with the app's glassmorphism theme.
struct AuthFormView: View {
    var onDismiss: (() -> Void)? = nil

    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var isSignUp = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case email, password, displayName }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                Text(isSignUp ? "Create Account" : "Welcome Back")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                VStack(spacing: 14) {
                    if isSignUp {
                        glassField(icon: "person", placeholder: "Display name (optional)", text: $displayName)
                            .focused($focusedField, equals: .displayName)
                    }

                    glassField(icon: "envelope", placeholder: "Email", text: $email)
                        .focused($focusedField, equals: .email)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()

                    glassField(icon: "lock", placeholder: "Password", text: $password, isSecure: true)
                        .focused($focusedField, equals: .password)
                        .textContentType(isSignUp ? .newPassword : .password)
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }

                Button {
                    submit()
                } label: {
                    Text(isSignUp ? "Create Account" : "Sign In")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSubmit ? .black : .white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(canSubmit ? Color.white : Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || isLoading)
                .overlay {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                HStack(spacing: 4) {
                    Text(isSignUp ? "Already have an account?" : "Don't have an account?")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSignUp.toggle()
                            errorMessage = nil
                        }
                    } label: {
                        Text(isSignUp ? "Sign In" : "Sign Up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                }

                if let onDismiss {
                    Divider()
                        .background(Color.white.opacity(0.1))
                        .padding(.horizontal, 20)
                    Button("Continue as Guest") { onDismiss() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(40)
            .frame(width: 400)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))

            Spacer()
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { focusedField = .email }
    }

    private func glassField(icon: String, placeholder: String, text: Binding<String>, isSecure: Bool = false) -> some View {
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

    private func submit() {
        focusedField = nil
        guard canSubmit else { return }
        isLoading = true
        errorMessage = nil

        Task {
            let success: Bool
            if isSignUp {
                success = await AuthManager.shared.signUp(
                    email: email.trimmingCharacters(in: .whitespaces),
                    password: password,
                    displayName: displayName.trimmingCharacters(in: .whitespaces)
                )
            } else {
                success = await AuthManager.shared.signIn(
                    email: email.trimmingCharacters(in: .whitespaces),
                    password: password
                )
            }
            await MainActor.run {
                isLoading = false
                if success {
                    onDismiss?()
                } else {
                    errorMessage = AuthManager.shared.errorMessage
                }
            }
        }
    }
}
