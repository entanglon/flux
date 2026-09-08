import Foundation

/// Response from PocketBase auth endpoints.
struct PBAuthResponse: Codable {
    let token: String
    let record: PBUserRecord
}

/// PocketBase user record embedded in auth responses.
struct PBUserRecord: Codable {
    let id: String
    let email: String?
    let name: String?
    let avatar: String?
    let created: String?
    let updated: String?
}
