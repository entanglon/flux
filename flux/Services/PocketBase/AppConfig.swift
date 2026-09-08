import Foundation

/// Centralized app configuration for the PocketBase backend.
enum AppConfig {
    /// PocketBase instance behind Tailscale Funnel.
    /// Override at runtime with UserDefaults key "pocketBaseURL".
    static var baseURL: URL {
        if let override = UserDefaults.standard.string(forKey: "pocketBaseURL"),
           let url = URL(string: override) { return url }
        return URL(string: "https://heisenbug.tailc311f6.ts.net")!
    }

    /// Redirect URI registered in Google Cloud Console and PocketBase.
    /// PocketBase serves an HTML page here after Google OAuth completes.
    static let oauthRedirectHost = "heisenbug.tailc311f6.ts.net"

    /// Full redirect URL sent to Google and PocketBase.
    static var oauthRedirectURL: String {
        "https://\(oauthRedirectHost)/api/oauth2-redirect"
    }

    /// PocketBase API base path.
    static let apiPath = "/api"

    /// Timeout for standard requests.
    static let requestTimeout: TimeInterval = 20

    /// Timeout for data push (larger payloads).
    static let pushTimeout: TimeInterval = 30
}
