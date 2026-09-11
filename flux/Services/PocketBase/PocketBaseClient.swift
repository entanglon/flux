import Foundation
import OSLog

/// Errors thrown by PocketBase API calls.
enum PocketBaseError: LocalizedError {
    case network
    case unauthorized
    case server(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .network: return "Could not reach the server. Check your connection."
        case .unauthorized: return "Session expired. Please sign in again."
        case .server(let msg): return msg
        case .decoding(let msg): return "Invalid response: \(msg)"
        }
    }
}

/// Lightweight HTTP client for the PocketBase API.
struct PocketBaseClient {
    static let shared = PocketBaseClient()

    private var base: URL { AppConfig.baseURL }

    // MARK: - Email/Password Auth

    /// Sign in with email and password.
    func authWithPassword(email: String, password: String) async throws -> PBAuthResponse {
        let body: [String: Any] = ["identity": email, "password": password]
        let req = try request(path: "/collections/users/auth-with-password", method: "POST", body: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PocketBaseError.network }
        if http.statusCode == 400 || http.statusCode == 401 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "Invalid email or password."
            throw PocketBaseError.server(msg)
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw PocketBaseError.server("auth failed (\(http.statusCode)): \(msg)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(PBAuthResponse.self, from: data)
        } catch {
            throw PocketBaseError.decoding(error.localizedDescription)
        }
    }

    /// Create a new account with email, password, and optional display name.
    func signUp(email: String, password: String, displayName: String?) async throws -> PBAuthResponse {
        var body: [String: Any] = ["email": email, "password": password, "passwordConfirm": password]
        if let name = displayName, !name.isEmpty {
            body["name"] = name
        }
        let req = try request(path: "/collections/users/records", method: "POST", body: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PocketBaseError.network }
        if http.statusCode == 400 {
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            let msg = obj?["message"] as? String ?? (obj?["data"] as? [String: Any])?.first?.value as? String ?? "Signup failed."
            throw PocketBaseError.server(msg)
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw PocketBaseError.server("signup failed (\(http.statusCode)): \(msg)")
        }
        // After creating the user, PocketBase requires a separate auth call to get the token.
        return try await authWithPassword(email: email, password: password)
    }

    /// Refresh an existing auth token.
    func authRefresh(token: String) async throws -> PBAuthResponse {
        var req = try request(path: "/collections/users/auth-refresh", method: "POST")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PocketBaseError.network }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PocketBaseError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw PocketBaseError.server("auth-refresh returned \(http.statusCode)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(PBAuthResponse.self, from: data)
        } catch {
            throw PocketBaseError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Data (user_data collection)

    /// Fetch the user's data record from PocketBase (newest first — duplicates
    /// from before the upsert fix may still exist server-side until cleaned).
    func fetchData(token: String, userID: String) async throws -> (id: String, payload: [String: Any], updatedAt: Double)? {
        let filter = "user=\"\(userID)\""
        var components = URLComponents(url: base.appendingPathComponent("/api/collections/user_data/records"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "sort", value: "-updatedAt")
        ]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = AppConfig.requestTimeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PocketBaseError.network }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else { throw PocketBaseError.unauthorized }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]],
              let record = items.first else {
            return nil
        }
        guard let id = record["id"] as? String,
              let payload = record["payload"] as? [String: Any],
              let updatedAt = record["updatedAt"] as? Double else {
            return nil
        }
        return (id, payload, updatedAt)
    }

    /// Create or update the user's data record. Self-healing: when the caller
    /// doesn't know the record id (fresh launch — the id was previously only
    /// tracked in memory), look it up first so we PATCH instead of POSTing a
    /// duplicate. One extra GET only in that case.
    @discardableResult
    func pushData(token: String, userID: String, payload: [String: Any], updatedAt: Double, existingRecordID: String?) async throws -> String? {
        let body: [String: Any] = [
            "user": userID,
            "payload": payload,
            "updatedAt": updatedAt
        ]

        var recordID = existingRecordID
        if recordID == nil {
            // Resolve-or-abort: a failed lookup must NEVER fall through to a
            // blind POST (that's how Sep-9 duplicate was born). Distinguish
            // "verified absent" (POST is correct) from "lookup failed" (abort;
            // a later sync retries — a skipped push self-heals, a dupe doesn't).
            var lookupFailed = false
            do {
                recordID = try await fetchData(token: token, userID: userID)?.id
            } catch {
                lookupFailed = true
            }
            if lookupFailed {
                try? await Task.sleep(nanoseconds: 500_000_000)
                do {
                    recordID = try await fetchData(token: token, userID: userID)?.id
                    lookupFailed = false
                } catch {
                    lookupFailed = true
                }
            }
            if lookupFailed {
                throw PocketBaseError.network
            }
        }

        var req: URLRequest
        if let recordID = recordID {
            req = URLRequest(url: base.appendingPathComponent("/api/collections/user_data/records/\(recordID)"))
            req.httpMethod = "PATCH"
        } else {
            req = URLRequest(url: base.appendingPathComponent("/api/collections/user_data/records"))
            req.httpMethod = "POST"
        }
        req.timeoutInterval = AppConfig.pushTimeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PocketBaseError.network }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw PocketBaseError.server("pushData failed: \(msg)")
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = obj["id"] as? String {
            return id
        }
        return existingRecordID
    }

    // MARK: - Request Builder

    func request(path: String, method: String, body: [String: Any]? = nil, token: String? = nil) throws -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent("/api" + path))
        req.httpMethod = method
        req.timeoutInterval = AppConfig.requestTimeout
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
