import Foundation

/// Cloudflare Workers backend configuration + client.
///
/// Identity is native email/password with HMAC-signed JWTs — no Firebase Auth dependency.
enum FluxCloudConfig {
    /// Deploy URL printed by `wrangler deploy`. Override at runtime with
    /// UserDefaults key "cloudBaseURL" (no rebuild needed).
    static var baseURL: URL {
        if let override = UserDefaults.standard.string(forKey: "cloudBaseURL"),
           let url = URL(string: override) { return url }
        return URL(string: "https://flux-backend.nemesys.workers.dev")!
    }
}

enum FluxCloudError: LocalizedError {
    case network, unauthorized, server(String)

    var errorDescription: String? {
        switch self {
        case .network: return "Could not reach the Flux service. Check your connection."
        case .unauthorized: return "Session expired. Please sign in again."
        case .server(let msg): return msg
        }
    }
}

/// Auth response from the Worker.
struct FluxAuthResponse {
    let uid: String
    let email: String
    let token: String
}

/// Thin URLSession wrapper over the Worker API.
struct FluxCloudClient {
    static let shared = FluxCloudClient()

    private var base: URL { FluxCloudConfig.baseURL }

    // MARK: - Auth

    func signUp(email: String, password: String) async throws -> FluxAuthResponse {
        let req = try request(path: "/v1/auth/signup", method: "POST", body: [
            "email": email, "password": password
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw FluxCloudError.network }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FluxCloudError.server("bad_response")
        }

        if http.statusCode == 409 { throw FluxCloudError.server(obj["error"] as? String ?? "That email already has an account.") }
        if http.statusCode == 400 { throw FluxCloudError.server(obj["error"] as? String ?? "Invalid input.") }
        guard (200...299).contains(http.statusCode) else { throw FluxCloudError.server("Signup failed.") }

        guard let uid = obj["uid"] as? String,
              let email = obj["email"] as? String,
              let token = obj["token"] as? String else {
            throw FluxCloudError.server("bad_response")
        }
        return FluxAuthResponse(uid: uid, email: email, token: token)
    }

    func signIn(email: String, password: String) async throws -> FluxAuthResponse {
        let req = try request(path: "/v1/auth/signin", method: "POST", body: [
            "email": email, "password": password
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw FluxCloudError.network }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FluxCloudError.server("bad_response")
        }

        if http.statusCode == 401 { throw FluxCloudError.server(obj["error"] as? String ?? "Invalid email or password.") }
        if http.statusCode == 400 { throw FluxCloudError.server(obj["error"] as? String ?? "Invalid input.") }
        guard (200...299).contains(http.statusCode) else { throw FluxCloudError.server("Sign in failed.") }

        guard let uid = obj["uid"] as? String,
              let email = obj["email"] as? String,
              let token = obj["token"] as? String else {
            throw FluxCloudError.server("bad_response")
        }
        return FluxAuthResponse(uid: uid, email: email, token: token)
    }

    // MARK: - Data

    func fetchData(token: String) async throws -> (payload: [String: Any], updatedAt: Double)? {
        let req = try request(path: "/v1/data", method: "GET", token: token)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw FluxCloudError.network }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else { throw FluxCloudError.unauthorized }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FluxCloudError.server("bad_response")
        }
        if obj["notFound"] as? Bool == true {
            return nil
        }
        guard let payload = obj["payload"] as? [String: Any],
              let updatedAt = obj["updatedAt"] as? Double else {
            throw FluxCloudError.server("bad_response")
        }
        return (payload, updatedAt)
    }

    /// Returns true when the push was superseded (server copy was newer).
    @discardableResult
    func pushData(token: String, payload: [String: Any], updatedAt: Double) async throws -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("/v1/data"))
        req.httpMethod = "PUT"
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["payload": payload, "updatedAt": updatedAt])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw FluxCloudError.unauthorized
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj["superseded"] as? Bool == true
        }
        return false
    }

    // MARK: - Private

    private func request(path: String, method: String, body: [String: Any]? = nil, token: String? = nil) throws -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 20
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }
}
