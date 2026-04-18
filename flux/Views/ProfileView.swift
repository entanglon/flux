import SwiftUI
import FirebaseAuth

struct ProfileView: View {
    @ObservedObject var authManager = AuthManager.shared
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Account")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
            .background(Color.black.opacity(0.2))
            
            ScrollView {
                VStack(spacing: 24) {
                    if let user = authManager.currentUser {
                        // User Info
                        VStack(spacing: 16) {
                            // Avatar
                            if let photoURL = user.photoURL {
                                AsyncImage(url: photoURL) { image in
                                    image.resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Color.gray.opacity(0.3)
                                }
                                .frame(width: 80, height: 80)
                                .clipShape(Circle())
                                .shadow(radius: 10)
                            } else {
                                Circle()
                                    .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 80, height: 80)
                                    .overlay(
                                        Text(String(user.email?.prefix(1) ?? "U").uppercased())
                                            .font(.system(size: 32, weight: .bold))
                                            .foregroundStyle(.white)
                                    )
                                    .shadow(radius: 10)
                            }
                            
                            VStack(spacing: 4) {
                                Text(user.displayName ?? "Flux User")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                Text(user.email ?? "")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 20)
                        
                        // Menu Items (Real Data)
                        VStack(spacing: 1) { // 1px spacing for separators
                            buildRow(title: "Name", value: user.displayName ?? "Not Set")
                            buildRow(title: "Email", value: user.email ?? "Not Set")
                            
                            if let creationDate = user.creationDate {
                                buildRow(title: "Joined", value: creationDate.formatted(date: .abbreviated, time: .omitted))
                            }
                        }
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(12)
                        
                        // Action Buttons
                        VStack(spacing: 1) {
                            Button(action: {
                                authManager.signOut()
                                dismiss()
                            }) {
                                HStack {
                                    Text("Sign Out")
                                        .foregroundStyle(.red)
                                    Spacer()
                                }
                                .padding()
                                .background(Color.white.opacity(0.05))
                            }
                            .buttonStyle(.plain)
                        }
                        .cornerRadius(12)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 400, height: 500)
        .background(VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow))
        .ignoresSafeArea()
    }
    
    @ViewBuilder
    func buildRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color.white.opacity(0.05))
    }
}

#Preview {
    ProfileView()
}
