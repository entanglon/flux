import Foundation
import OSLog

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.kernelmoth.flux"

    static let auth = Logger(subsystem: subsystem, category: "Auth")
    static let player = Logger(subsystem: subsystem, category: "Player")
    static let server = Logger(subsystem: subsystem, category: "Server")
    static let stream = Logger(subsystem: subsystem, category: "Stream")
    static let tmdb = Logger(subsystem: subsystem, category: "TMDB")
    static let sync = Logger(subsystem: subsystem, category: "Sync")
    static let ui = Logger(subsystem: subsystem, category: "UI")
}
