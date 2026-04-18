import Foundation
import SwiftUI
import Combine

struct TMDBEnrichedData {
    let cast: [CastMember]?
    let providers: [WatchProvider]?
    let seasons: [Season]?
    let heroURL: URL?
    let tmdbID: Int?
    func getImdbID(tmdbID: String, type: String) async -> String? {
        let key = UserDefaults.standard.string(forKey: "tmdbApiKey") ?? ""
        if key.isEmpty { return nil }
        
        let pathType = type == "series" ? "tv" : "movie"
        guard let url = URL(string: "https://api.themoviedb.org/3/\(pathType)/\(tmdbID)/external_ids?api_key=\(key)") else { return nil }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let resp = response as? HTTPURLResponse, resp.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let imdb = json?["imdb_id"] as? String, !imdb.isEmpty {
                return imdb
            }
        } catch { print(error) }
        return nil
    }
}

class TMDBEnricher {
    static let shared = TMDBEnricher()
    
    private init() {}
    
    func enrichContent(imdbID: String, category: String) async -> TMDBEnrichedData? {
        let key = UserDefaults.standard.string(forKey: "tmdbApiKey") ?? ""
        if key.isEmpty { return nil }
        
        let type = category == "TV Show" ? "tv" : "movie"
        
        // 1. Find TMDB ID using IMDb ID
        guard let url = URL(string: "https://api.themoviedb.org/3/find/\(imdbID)?api_key=\(key)&external_source=imdb_id") else { return nil }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            
            let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            var tmdbID: Int? = nil
            
            if type == "movie" {
                if let results = json?["movie_results"] as? [[String: Any]], let first = results.first {
                    tmdbID = first["id"] as? Int
                }
            } else {
                if let results = json?["tv_results"] as? [[String: Any]], let first = results.first {
                    tmdbID = first["id"] as? Int
                }
            }
            
            guard let id = tmdbID else { return nil }
            
            let useRichMetadata = UserDefaults.standard.bool(forKey: "enableRichMetadata")
            
            async let enrichedCast = fetchCast(id: id, type: type, key: key)
            async let enrichedProviders = fetchProviders(id: id, type: type, key: key)
            
            var seasons: [Season]? = nil
            var heroURL: URL? = nil
            
            if useRichMetadata {
                do {
                    if type == "movie" {
                        let movieDetails = try await TMDBClient.shared.fetchMovieDetails(id: id)
                        if let backdrop = movieDetails.backdropPath {
                            heroURL = URL(string: "https://image.tmdb.org/t/p/original\(backdrop)")
                        }
                    } else {
                        let tvDetails = try await TMDBClient.shared.fetchTVShowDetails(id: id)
                        if let backdrop = tvDetails.backdropPath {
                            heroURL = URL(string: "https://image.tmdb.org/t/p/original\(backdrop)")
                        }
                        // Enrich seasons too
                        if let tmdbSeasons = tvDetails.seasons {
                            seasons = tmdbSeasons.map { $0.toSeason() }
                        }
                    }
                } catch {
                    print("Failed to enrich original details: \(error)")
                }
            }
            
            let (cast, providers) = await (enrichedCast, enrichedProviders)
            
            return TMDBEnrichedData(
                cast: cast, 
                providers: providers, 
                seasons: seasons, 
                heroURL: heroURL, 
                tmdbID: id
            )
            
        } catch {
            print("TMDB Enrich error: \(error)")
            return nil
        }
    }
    
    private func fetchCast(id: Int, type: String, key: String) async -> [CastMember]? {
        guard let creditsURL = URL(string: "https://api.themoviedb.org/3/\(type)/\(id)/credits?api_key=\(key)") else { return nil }
        do {
            let (creditsData, creditsResponse) = try await URLSession.shared.data(from: creditsURL)
            guard let credResp = creditsResponse as? HTTPURLResponse, credResp.statusCode == 200 else { return nil }
            
            let credJson = try JSONSerialization.jsonObject(with: creditsData, options: []) as? [String: Any]
            guard let castArray = credJson?["cast"] as? [[String: Any]] else { return nil }
            
            var enrichedCast: [CastMember] = []
            for member in castArray.prefix(15) { // take top 15
                if let name = member["name"] as? String {
                    let role = member["character"] as? String
                    var imageURL: URL? = nil
                    if let path = member["profile_path"] as? String {
                        imageURL = URL(string: "https://image.tmdb.org/t/p/w1280\(path)")
                    }
                    enrichedCast.append(CastMember(name: name, role: role, imageURL: imageURL))
                }
            }
            return enrichedCast
        } catch {
            return nil
        }
    }
    
    private func fetchProviders(id: Int, type: String, key: String) async -> [WatchProvider]? {
        // Find region from Locale
        let region = Locale.current.region?.identifier ?? "US"
        guard let providersURL = URL(string: "https://api.themoviedb.org/3/\(type)/\(id)/watch/providers?api_key=\(key)") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: providersURL)
            guard let resp = response as? HTTPURLResponse, resp.statusCode == 200 else { return nil }
            
            let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            guard let results = json?["results"] as? [String: Any] else { return nil }
            
            guard let regionNode = results[region] as? [String: Any] ?? results["US"] as? [String: Any] else { return nil }
            
            var providerList: [WatchProvider] = []
            
            // Collect flatrate (stream) providers typically
            if let flatrate = regionNode["flatrate"] as? [[String: Any]] {
                for prov in flatrate {
                    if let pid = prov["provider_id"] as? Int, let name = prov["provider_name"] as? String {
                        var logo: URL? = nil
                        if let path = prov["logo_path"] as? String {
                            logo = URL(string: "https://image.tmdb.org/t/p/w200\(path)")
                        }
                        providerList.append(WatchProvider(id: pid, name: name, logoURL: logo))
                    }
                }
            }
            return providerList.isEmpty ? nil : providerList
        } catch {
            return nil
        }
    }
    func getImdbID(tmdbID: String, type: String) async -> String? {
        let key = UserDefaults.standard.string(forKey: "tmdbApiKey") ?? ""
        if key.isEmpty { return nil }
        
        let pathType = type == "series" ? "tv" : "movie"
        guard let url = URL(string: "https://api.themoviedb.org/3/\(pathType)/\(tmdbID)/external_ids?api_key=\(key)") else { return nil }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let resp = response as? HTTPURLResponse, resp.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let imdb = json?["imdb_id"] as? String, !imdb.isEmpty {
                return imdb
            }
        } catch { print(error) }
        return nil
    }
}
