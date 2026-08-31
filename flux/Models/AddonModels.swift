import Foundation
import SwiftUI

public enum AddonCategory: String, Codable, CaseIterable, Identifiable {
    case all = "All"
    case installed = "Installed"
    case official = "Official"
    case streamingServices = "Streaming Platforms"
    case publicDomain = "Free & Public Domain"
    case community = "Community Streams"
    case subtitles = "Subtitles"
    
    public var id: String { rawValue }
    
    public var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .installed: return "checkmark.circle"
        case .official: return "checkmark.seal"
        case .streamingServices: return "play.tv"
        case .publicDomain: return "building.columns"
        case .community: return "globe"
        case .subtitles: return "captions.bubble"
        }
    }
}

public struct StremioCatalog: Codable, Hashable {
    public var type: String
    public var id: String
    public var name: String?
    
    public init(type: String, id: String, name: String? = nil) {
        self.type = type
        self.id = id
        self.name = name
    }
}

public struct StremioAddon: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var description: String?
    public var version: String?
    public var logoURL: String?
    public var iconURL: String?
    public var url: String
    public var transportUrl: String
    public var isEnabled: Bool
    public var isStock: Bool
    public var category: String?
    public var catalogs: [StremioCatalog]?
    public var resources: [String]?
    
    public init(
        id: String,
        name: String,
        description: String? = nil,
        version: String? = nil,
        logoURL: String? = nil,
        iconURL: String? = nil,
        url: String,
        transportUrl: String,
        isEnabled: Bool = true,
        isStock: Bool = false,
        category: String? = nil,
        catalogs: [StremioCatalog]? = nil,
        resources: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.logoURL = logoURL
        self.iconURL = iconURL
        self.url = url
        self.transportUrl = transportUrl
        self.isEnabled = isEnabled
        self.isStock = isStock
        self.category = category
        self.catalogs = catalogs
        self.resources = resources
    }
}

public struct AddonManifest: Codable {
    public let id: String
    public let name: String
    public let version: String?
    public let description: String?
    public let logo: String?
    public let icon: String?
    public let resources: [String]?
    public let types: [String]?
    public let catalogs: [StremioCatalog]?
    public let idPrefixes: [String]?
    public let behaviorHints: AddonBehaviorHints?
}

public struct AddonBehaviorHints: Codable {
    public let adult: Bool?
    public let p2p: Bool?
    public let configurable: Bool?
    public let configurationRequired: Bool?
}
