import Foundation
import FirebaseAuth
import Combine

class AuthManager: ObservableObject {
    static let shared = AuthManager()
    
    @Published var currentUser: User?
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private var authStateListenerHandle: AuthStateDidChangeListenerHandle?
    
    private init() {
        // Start listening to auth changes immediately
        /*
        authStateListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            DispatchQueue.main.async {
                self?.currentUser = user
                self?.isAuthenticated = (user != nil)
                
                if let user = user {
                    print("User is signed in: \(user.email ?? "No Email")")
                    // Start syncing data when user signs in
                    UserDataService.shared.startSyncing(user: user)
                } else {
                    print("User is signed out")
                    UserDataService.shared.stopSyncing()
                }
            }
        }
        */
    }
    
    deinit {
        /*
        if let handle = authStateListenerHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
        */
    }
    
    // MARK: - Auth Actions
    
    func signIn(email: String, password: String) async {
        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
            // Dummy authentication bypassing firebase
            // self.isAuthenticated = true
            self.isLoading = false
        }
        /*
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            print("Sign in successful: \(result.user.uid)")
            DispatchQueue.main.async {
                self.isLoading = false
            }
        } catch {
            print("Sign in failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
        */
    }
    
    func signUp(email: String, password: String) async {
        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
            self.isLoading = false
        }
        /*
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            print("Sign up successful: \(result.user.uid)")
            DispatchQueue.main.async {
                self.isLoading = false
            }
        } catch {
            print("Sign up failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
        */
    }
    
    func signOut() {
        /*
        do {
            try Auth.auth().signOut()
        } catch {
            print("Error signing out: \(error)")
            self.errorMessage = error.localizedDescription
        }
        */
    }
}
