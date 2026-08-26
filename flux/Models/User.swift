import Foundation

/// App-level user identity.
struct User: Equatable {
    let id: String
    let email: String?
    let displayName: String?
    let photoURL: URL?
    let creationDate: Date?

    init(id: String, email: String? = nil, displayName: String? = nil, photoURL: URL? = nil, creationDate: Date? = nil) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.photoURL = photoURL
        self.creationDate = creationDate
    }
}
