import SwiftUI

struct AuthView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var errorMessage: String?
    @State private var isLoading = false
    
    @Environment(\.dismiss) var dismiss
    @ObservedObject var authManager = AuthManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isSignUp ? "Create Account" : "Sign In")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
            .background(Color.black.opacity(0.2))
            
            ScrollView {
                VStack(spacing: 24) {
                    // Logo/Icon
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .padding(.top, 20)
                    
                    Text(isSignUp ? "Sign up to track your shows." : "Sign in to access your library.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    // Fields Container
                    VStack(spacing: 1) {
                        TextField("Email", text: $email)
                            .textFieldStyle(.plain)
                            .padding()
                            .background(Color.white.opacity(0.05))
                        
                        SecureField("Password", text: $password)
                            .textFieldStyle(.plain)
                            .padding()
                            .background(Color.white.opacity(0.05))
                    }
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    
                    // Action Button
                    Button(action: handleAuth) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text(isSignUp ? "Sign Up" : "Sign In")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading || email.isEmpty || password.isEmpty)
                    .opacity((isLoading || email.isEmpty || password.isEmpty) ? 0.6 : 1)
                    
                    // Toggle Mode
                    Button(action: {
                        withAnimation {
                            isSignUp.toggle()
                            errorMessage = nil
                        }
                    }) {
                        Text(isSignUp ? "Already have an account? Sign In" : "Don't have an account? Sign Up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(30)
            }
        }
        .frame(width: 400, height: 450)
        .glassEffect(.regular, in: .rect)
        .ignoresSafeArea()
        // Listeners
        .onChange(of: authManager.currentUser) { _, user in
            if user != nil {
                dismiss()
            }
        }
        .onChange(of: authManager.errorMessage) { _, error in
            if let error = error {
                self.errorMessage = error
                self.isLoading = false
            }
        }
        .onChange(of: authManager.isLoading) { _, loading in
            self.isLoading = loading
        }
    }
    
    private func handleAuth() {
        isLoading = true
        errorMessage = nil
        
        Task {
            if isSignUp {
                await AuthManager.shared.signUp(email: email, password: password)
            } else {
                await AuthManager.shared.signIn(email: email, password: password)
            }
        }
    }
}

#Preview {
    AuthView()
}
