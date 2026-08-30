import Foundation

/// Unified domain error types for Flux subsystems.
/// Provides user-friendly descriptions and error recovery insights.
enum FluxError: Error, LocalizedError, Equatable {
    case streaming(StreamingError)
    case tmdb(TMDBError)
    case auth(AuthError)
    case sync(SyncError)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .streaming(let err): return err.errorDescription
        case .tmdb(let err): return err.errorDescription
        case .auth(let err): return err.errorDescription
        case .sync(let err): return err.errorDescription
        case .unknown(let msg): return msg
        }
    }
}

// MARK: - Streaming Subsystem Errors

enum StreamingError: Error, LocalizedError, Equatable {
    case noStreamsFound
    case serverUnavailable
    case invalidInfoHash(String)
    case playbackFailed(reason: String)
    case streamTimeout
    case torrentEngineOffline

    var errorDescription: String? {
        switch self {
        case .noStreamsFound:
            return "No playable streams found for this title."
        case .serverUnavailable:
            return "The streaming engine server is unreachable. Please check your connection."
        case .invalidInfoHash(let hash):
            return "Invalid torrent info hash format: \(hash)"
        case .playbackFailed(let reason):
            return "Playback failed: \(reason)"
        case .streamTimeout:
            return "Stream resolution timed out. The peer swarm may be inactive."
        case .torrentEngineOffline:
            return "FluxEngine torrent backend is currently offline."
        }
    }
}

// MARK: - TMDB Subsystem Errors

enum TMDBError: Error, LocalizedError, Equatable {
    case invalidAPIKey
    case itemNotFound(id: String)
    case networkError(statusCode: Int)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Invalid TMDB API key. Please check your key in Settings."
        case .itemNotFound(let id):
            return "Metadata not found for ID: \(id)"
        case .networkError(let code):
            return "TMDB network request failed with status code \(code)."
        case .decodingError:
            return "Failed to parse TMDB metadata response."
        }
    }
}

// MARK: - Auth Subsystem Errors

enum AuthError: Error, LocalizedError, Equatable {
    case invalidCredentials
    case sessionExpired
    case networkFailure
    case serverError(String)
    case userNotFound

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Incorrect email or password."
        case .sessionExpired:
            return "Your login session has expired. Please sign in again."
        case .networkFailure:
            return "Unable to connect to authentication servers."
        case .serverError(let message):
            return message
        case .userNotFound:
            return "No account found with this email."
        }
    }
}

// MARK: - Sync Subsystem Errors

enum SyncError: Error, LocalizedError, Equatable {
    case unauthorized
    case payloadCorrupt
    case networkError

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Unauthorized cloud sync attempt."
        case .payloadCorrupt:
            return "Cloud sync payload was unreadable."
        case .networkError:
            return "Failed to synchronize with cloud database."
        }
    }
}
