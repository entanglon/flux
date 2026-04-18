import Foundation
import Combine

class TraktManager: ObservableObject {
    static let shared = TraktManager()
    
    @Published var isAuthenticated: Bool = false
    
    private let tokenUrl = "https://api.trakt.tv/oauth/token"
    private let redirectURI = "urn:ietf:wg:oauth:2.0:oob"
    
    init() {
        self.isAuthenticated = UserDefaults.standard.string(forKey: "traktAccessToken") != nil
    }
    
    var authorizationURL: URL {
        URL(string: "https://trakt.tv/oauth/authorize?response_type=code&client_id=\(Secrets.traktClientId)&redirect_uri=\(redirectURI)")!
    }
    
    func exchangeCodeForToken(code: String, completion: @escaping (Bool, Error?) -> Void) {
        guard let url = URL(string: tokenUrl) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "code": code,
            "client_id": Secrets.traktClientId,
            "client_secret": Secrets.traktClientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(false, error) }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async { completion(false, nil) }
                return
            }
            
            do {
                if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let accessToken = dict["access_token"] as? String {
                    DispatchQueue.main.async {
                        UserDefaults.standard.set(accessToken, forKey: "traktAccessToken")
                        if let refreshToken = dict["refresh_token"] as? String {
                            UserDefaults.standard.set(refreshToken, forKey: "traktRefreshToken")
                        }
                        self.isAuthenticated = true
                        completion(true, nil)
                    }
                } else {
                    DispatchQueue.main.async { completion(false, nil) }
                }
            } catch {
                DispatchQueue.main.async { completion(false, error) }
            }
        }.resume()
    }
    
    func logout() {
        UserDefaults.standard.removeObject(forKey: "traktAccessToken")
        UserDefaults.standard.removeObject(forKey: "traktRefreshToken")
        isAuthenticated = false
    }
}
