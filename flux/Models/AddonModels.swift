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

public struct StremioCatalogExtra: Codable, Hashable {
    public var name: String
    public var isRequired: Bool?
    public var options: [String]?
    public var optionsLimit: Int?
    
    public init(name: String, isRequired: Bool? = nil, options: [String]? = nil, optionsLimit: Int? = nil) {
        self.name = name
        self.isRequired = isRequired
        self.options = options
        self.optionsLimit = optionsLimit
    }
}

public struct StremioCatalog: Codable, Hashable {
    public var type: String
    public var id: String
    public var name: String?
    public var pageSize: Int?
    public var extra: [StremioCatalogExtra]?
    public var extraSupported: [String]?
    public var extraRequired: [String]?
    
    public init(type: String, id: String, name: String? = nil, pageSize: Int? = nil, extra: [StremioCatalogExtra]? = nil) {
        self.type = type
        self.id = id
        self.name = name
        self.pageSize = pageSize
        self.extra = extra
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? ""
        self.id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        self.name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.pageSize = try? container.decodeIfPresent(Int.self, forKey: .pageSize)
        self.extra = try? container.decodeIfPresent([StremioCatalogExtra].self, forKey: .extra)
        self.extraSupported = try? container.decodeIfPresent([String].self, forKey: .extraSupported)
        self.extraRequired = try? container.decodeIfPresent([String].self, forKey: .extraRequired)
    }
    
    private enum CodingKeys: String, CodingKey {
        case type, id, name, pageSize, extra, extraSupported, extraRequired
    }
}

public struct AddonResource: Codable, Hashable {
    public var name: String
    public var types: [String]?
    public var idPrefixes: [String]?
    
    public init(name: String, types: [String]? = nil, idPrefixes: [String]? = nil) {
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
    }
    
    public init(from decoder: Decoder) throws {
        if let singleVal = try? decoder.singleValueContainer(),
           let stringVal = try? singleVal.decode(String.self) {
            self.name = stringVal
            self.types = nil
            self.idPrefixes = nil
            return
        }
        
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.types = try? container.decodeIfPresent([String].self, forKey: .types)
        self.idPrefixes = try? container.decodeIfPresent([String].self, forKey: .idPrefixes)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(types, forKey: .types)
        try container.encodeIfPresent(idPrefixes, forKey: .idPrefixes)
    }
    
    private enum CodingKeys: String, CodingKey {
        case name, types, idPrefixes
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
    public let background: String?
    public let resources: [AddonResource]?
    public let types: [String]?
    public let catalogs: [StremioCatalog]?
    public let idPrefixes: [String]?
    public let behaviorHints: AddonBehaviorHints?
    
    /// Normalizes resources to [String] (e.g. ["stream", "subtitles", "catalog"])
    public var resourceNames: [String] {
        return resources?.map { $0.name } ?? []
    }
    
    public init(
        id: String,
        name: String,
        version: String? = nil,
        description: String? = nil,
        logo: String? = nil,
        icon: String? = nil,
        background: String? = nil,
        resources: [AddonResource]? = nil,
        types: [String]? = nil,
        catalogs: [StremioCatalog]? = nil,
        idPrefixes: [String]? = nil,
        behaviorHints: AddonBehaviorHints? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.logo = logo
        self.icon = icon
        self.background = background
        self.resources = resources
        self.types = types
        self.catalogs = catalogs
        self.idPrefixes = idPrefixes
        self.behaviorHints = behaviorHints
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        
        // Flexible version decoding (String or Number)
        if let verStr = try? container.decodeIfPresent(String.self, forKey: .version) {
            self.version = verStr
        } else if let verNum = try? container.decodeIfPresent(Double.self, forKey: .version) {
            self.version = String(verNum)
        } else if let verInt = try? container.decodeIfPresent(Int.self, forKey: .version) {
            self.version = String(verInt)
        } else {
            self.version = nil
        }
        
        self.description = try? container.decodeIfPresent(String.self, forKey: .description)
        self.logo = try? container.decodeIfPresent(String.self, forKey: .logo)
        self.icon = try? container.decodeIfPresent(String.self, forKey: .icon)
        self.background = try? container.decodeIfPresent(String.self, forKey: .background)
        self.resources = try? container.decodeIfPresent([AddonResource].self, forKey: .resources)
        self.types = try? container.decodeIfPresent([String].self, forKey: .types)
        self.catalogs = try? container.decodeIfPresent([StremioCatalog].self, forKey: .catalogs)
        self.idPrefixes = try? container.decodeIfPresent([String].self, forKey: .idPrefixes)
        self.behaviorHints = try? container.decodeIfPresent(AddonBehaviorHints.self, forKey: .behaviorHints)
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, name, version, description, logo, icon, background, resources, types, catalogs, idPrefixes, behaviorHints
    }
}

public struct AddonBehaviorHints: Codable {
    public let adult: Bool?
    public let p2p: Bool?
    public let configurable: Bool?
    public let configurationRequired: Bool?
    
    public init(adult: Bool? = nil, p2p: Bool? = nil, configurable: Bool? = nil, configurationRequired: Bool? = nil) {
        self.adult = adult
        self.p2p = p2p
        self.configurable = configurable
        self.configurationRequired = configurationRequired
    }
}
