import Foundation
import Combine

struct User: Equatable {
    let id: String
    let email: String?
    let displayName: String?
    let photoURL: URL?
    let creationDate: Date?
}

class AuthManager: ObservableObject {
    static let shared = AuthManager()
    
    @Published var currentUser: User?
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private init() {
        // Local-only dummy auth for now
        self.isAuthenticated = false
    }
    
    // MARK: - Auth Actions
    
    func signIn(email: String, password: String) async {
        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
            // Simulated local sign-in
            self.currentUser = User(id: UUID().uuidString, email: email, displayName: email.components(separatedBy: "@").first ?? "User", photoURL: nil, creationDate: Date())
            self.isAuthenticated = true
            self.isLoading = false
        }
    }
    
    func signUp(email: String, password: String) async {
        await signIn(email: email, password: password)
    }
    
    func signOut() {
        DispatchQueue.main.async {
            self.currentUser = nil
            self.isAuthenticated = false
        }
    }
}
