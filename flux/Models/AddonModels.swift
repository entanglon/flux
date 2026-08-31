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

public struct StoreAddonItem: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let summary: String
    public let version: String
    public let author: String
    public let manifestURL: String
    public let configureURL: String?
    public let logoURL: String?
    public let category: AddonCategory
    public let tags: [String]
    public let isStock: Bool
    
    public init(
        id: String,
        name: String,
        summary: String,
        version: String,
        author: String = "Community",
        manifestURL: String,
        configureURL: String? = nil,
        logoURL: String? = nil,
        category: AddonCategory,
        tags: [String] = [],
        isStock: Bool = false
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.version = version
        self.author = author
        self.manifestURL = manifestURL
        self.configureURL = configureURL
        self.logoURL = logoURL
        self.category = category
        self.tags = tags
        self.isStock = isStock
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
    
    enum CodingKeys: String, CodingKey {
        case id, name, description, version, logoURL, iconURL, url, transportUrl, isEnabled, isStock, category, catalogs, resources
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.version = try container.decodeIfPresent(String.self, forKey: .version)
        self.logoURL = try container.decodeIfPresent(String.self, forKey: .logoURL)
        self.iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        self.url = try container.decode(String.self, forKey: .url)
        self.transportUrl = try container.decode(String.self, forKey: .transportUrl)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.isStock = try container.decodeIfPresent(Bool.self, forKey: .isStock) ?? (self.id == "opensubtitles3" || self.id.contains("official"))
        self.category = try container.decodeIfPresent(String.self, forKey: .category)
        self.catalogs = try container.decodeIfPresent([StremioCatalog].self, forKey: .catalogs)
        self.resources = try container.decodeIfPresent([String].self, forKey: .resources)
    }
}

public struct AddonManifest: Codable {
    public var id: String
    public var name: String
    public var description: String?
    public var version: String?
    public var logo: String?
    public var icon: String?
    public var background: String?
    public var catalogs: [StremioCatalog]?
    public var resources: [String]?
}

public struct AddonStoreCatalog {
    public static let curatedAddons: [StoreAddonItem] = [
        // MARK: - Official & Subtitles
        StoreAddonItem(
            id: "opensubtitles3",
            name: "OpenSubtitles v3",
            summary: "Official multi-language subtitle search directly in the player.",
            version: "1.0.0",
            author: "Official",
            manifestURL: "https://opensubtitles-v3.strem.io/manifest.json",
            logoURL: "https://app.strem.io/images/addons/opensubtitles.png",
            category: .subtitles,
            tags: ["Official", "Subtitles", "Multi-Language"],
            isStock: true
        ),
        
        // MARK: - Streaming Platforms & Deep Links
        StoreAddonItem(
            id: "official.watchhub",
            name: "WatchHub",
            summary: "Direct stream launcher for Netflix, Prime Video, Disney+, Apple TV+, and Hulu.",
            version: "1.0.2",
            author: "Official",
            manifestURL: "https://watchhub.strem.io/manifest.json",
            logoURL: "https://app.strem.io/images/addons/watchhub.png",
            category: .streamingServices,
            tags: ["Official", "Netflix", "Prime Video", "Apple TV+", "Disney+"]
        ),
        
        // MARK: - Free & Public Domain
        StoreAddonItem(
            id: "community.internetarchive",
            name: "Internet Archive Movies",
            summary: "Thousands of public domain films, classic cinema, and historical archives.",
            version: "1.0.0",
            author: "Archive.org",
            manifestURL: "https://ia-stremio.elfhosted.com/manifest.json",
            logoURL: "https://ia-stremio.elfhosted.com/logo.png",
            category: .publicDomain,
            tags: ["Free", "Public Domain", "Classic Movies", "HTTP"]
        ),
        StoreAddonItem(
            id: "official.youtube",
            name: "YouTube Channels & Streams",
            summary: "Official trailers, gameplay streams, podcasts, and open YouTube videos.",
            version: "1.1.0",
            author: "Community",
            manifestURL: "https://youtube.strem.fun/manifest.json",
            logoURL: "https://app.strem.io/images/addons/youtube.png",
            category: .publicDomain,
            tags: ["Trailers", "Clips", "Live Video", "Free"]
        ),
        StoreAddonItem(
            id: "community.publiciptv",
            name: "Free-to-Air Public IPTV",
            summary: "Legal free-to-air international news, sports, and culture broadcasts.",
            version: "1.0.0",
            author: "FreeIPTV",
            manifestURL: "https://free-iptv.strem.fun/manifest.json",
            logoURL: "https://free-iptv.strem.fun/logo.png",
            category: .publicDomain,
            tags: ["Free-to-Air", "Live TV", "News", "M3U8"]
        ),
        
        // MARK: - Community Providers
        StoreAddonItem(
            id: "com.stremio.torrentio",
            name: "Torrentio",
            summary: "High-speed torrent and Debrid streams with real-time seeder health and resolution ranking.",
            version: "0.0.15",
            author: "TheCommunity",
            manifestURL: "https://torrentio.strem.fun/manifest.json",
            configureURL: "https://torrentio.strem.fun/configure",
            logoURL: "https://torrentio.strem.fun/logo.png",
            category: .community,
            tags: ["Torrents", "Debrid-Ready", "Fast Start", "4K HDR"]
        ),
        StoreAddonItem(
            id: "com.stremio.comet",
            name: "Comet",
            summary: "Ultra-fast torrent & Debrid scraper hosted on ElfHosted infrastructure.",
            version: "2.0.0",
            author: "ElfHosted",
            manifestURL: "https://comet.elfhosted.com/manifest.json",
            configureURL: "https://comet.elfhosted.com/configure",
            logoURL: "https://comet.elfhosted.com/logo.png",
            category: .community,
            tags: ["Torrents", "Debrid", "High Speed"]
        ),
        StoreAddonItem(
            id: "community.mediafusion",
            name: "MediaFusion",
            summary: "Multi-source community provider with support for live sports, torrents, and direct streams.",
            version: "3.2.0",
            author: "MediaFusion",
            manifestURL: "https://mediafusion.elfhosted.com/manifest.json",
            configureURL: "https://mediafusion.elfhosted.com/configure",
            logoURL: "https://mediafusion.elfhosted.com/logo.png",
            category: .community,
            tags: ["Multi-Source", "Torrents", "Debrid"]
        ),
        StoreAddonItem(
            id: "community.meteor",
            name: "Meteor",
            summary: "Franchise-aware intelligent stream matching and torrent ranking.",
            version: "1.0.0",
            author: "MidnightIgnite",
            manifestURL: "https://meteorfortheweebs.midnightignite.me/manifest.json",
            logoURL: "https://meteorfortheweebs.midnightignite.me/logo.png",
            category: .community,
            tags: ["Torrents", "Franchise-Aware", "Anime"]
        ),
        StoreAddonItem(
            id: "stremify.elfhosted.com",
            name: "Stremify",
            summary: "Direct HTTP web streams from popular public streaming providers.",
            version: "1.0.0",
            author: "ElfHosted",
            manifestURL: "https://stremify.elfhosted.com/manifest.json",
            logoURL: "https://stremify.elfhosted.com/logo.png",
            category: .community,
            tags: ["HTTP Streams", "Web Direct", "No P2P"]
        ),
        StoreAddonItem(
            id: "community.stremio.webstreamrmbg",
            name: "WebStreamr",
            summary: "Fast direct HTTP streaming provider with proxy support.",
            version: "1.0.0",
            author: "Community",
            manifestURL: "https://87d6a6ef6b58-webstreamrmbg.baby-beamup.club/manifest.json",
            logoURL: "https://87d6a6ef6b58-webstreamrmbg.baby-beamup.club/logo.png",
            category: .community,
            tags: ["HTTP", "Direct Streams", "No P2P"]
        ),
        StoreAddonItem(
            id: "community.cyberflix",
            name: "CyberFlix Catalog",
            summary: "Curated streaming catalogues and browse rails for trending titles across all platforms.",
            version: "1.4.0",
            author: "CyberFlix",
            manifestURL: "https://cyberflix.elfhosted.com/manifest.json",
            configureURL: "https://cyberflix.elfhosted.com/configure",
            logoURL: "https://cyberflix.elfhosted.com/logo.png",
            category: .community,
            tags: ["Catalogs", "Trending", "Curated"]
        )
    ]
}
