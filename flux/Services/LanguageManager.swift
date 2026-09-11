import Foundation
import Combine
import SwiftUI

// MARK: - Supported App Languages

public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case english = "en"
    case japanese = "ja"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case korean = "ko"
    case hindi = "hi"
    case chinese = "zh"

    public var id: String { rawValue }

    /// Human-readable display label with English and native names.
    public var displayName: String {
        switch self {
        case .english: return "English"
        case .japanese: return "日本語 (Japanese)"
        case .spanish: return "Español (Spanish)"
        case .french: return "Français (French)"
        case .german: return "Deutsch (German)"
        case .italian: return "Italiano (Italian)"
        case .portuguese: return "Português (Portuguese)"
        case .korean: return "한국어 (Korean)"
        case .hindi: return "हिन्दी (Hindi)"
        case .chinese: return "简体中文 (Chinese)"
        }
    }

    /// Native script name only.
    public var nativeName: String {
        switch self {
        case .english: return "English"
        case .japanese: return "日本語"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .italian: return "Italiano"
        case .portuguese: return "Português"
        case .korean: return "한국어"
        case .hindi: return "हिन्दी"
        case .chinese: return "简体中文"
        }
    }

    /// Regional TMDB language parameter (e.g. ja-JP, es-ES, en-US).
    public var tmdbCode: String {
        switch self {
        case .english: return "en-US"
        case .japanese: return "ja-JP"
        case .spanish: return "es-ES"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .italian: return "it-IT"
        case .portuguese: return "pt-BR"
        case .korean: return "ko-KR"
        case .hindi: return "hi-IN"
        case .chinese: return "zh-CN"
        }
    }

    /// ISO-639-1 two-letter code.
    public var isoCode: String { rawValue }

    /// Audio language name used in Player audio tracks and settings.
    public var audioLanguageName: String {
        switch self {
        case .english: return "English"
        case .japanese: return "Japanese"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .korean: return "Korean"
        case .hindi: return "Hindi"
        case .chinese: return "Chinese"
        }
    }
}

// MARK: - Reactive Language Manager

@MainActor
public final class LanguageManager: ObservableObject {
    public static let shared = LanguageManager()

    @Published public private(set) var currentLanguage: AppLanguage

    private init() {
        let savedRaw = UserDefaults.standard.string(forKey: UserDefaults.Key.appLanguage) ?? "en"
        self.currentLanguage = AppLanguage(rawValue: savedRaw) ?? .english
    }

    /// Sets the active application language and persists across profiles.
    public func setLanguage(_ language: AppLanguage) {
        guard language != currentLanguage else { return }
        currentLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: UserDefaults.Key.appLanguage)
        ProfileManager.shared.saveCurrentProfileSettings()
        AuthManager.shared.scheduleAutoSync()

        // Invalidate TMDB catalog and metadata in-memory caches so rails re-fetch in the new language
        Task {
            await TMDBCatalogCacheActor.shared.clear()
            await TMDBEnricher.shared.clearMemoryCache()
            NotificationCenter.default.post(name: .fluxRefresh, object: nil)
        }
    }

    /// Synchronizes language from a profile switch without re-triggering save loops.
    public func syncFromProfile(_ rawLanguage: String?) {
        guard let raw = rawLanguage, let lang = AppLanguage(rawValue: raw) else { return }
        if lang != currentLanguage {
            currentLanguage = lang
            UserDefaults.standard.set(lang.rawValue, forKey: UserDefaults.Key.appLanguage)
            Task {
                await TMDBCatalogCacheActor.shared.clear()
                await TMDBEnricher.shared.clearMemoryCache()
                NotificationCenter.default.post(name: .fluxRefresh, object: nil)
            }
        }
    }
}

// MARK: - UI Localization Dictionary (L10n)

public struct L10n {
    /// Translates a key for the currently active AppLanguage. Falls back to English if untranslated.
    @MainActor
    public static func tr(_ key: String) -> String {
        let lang = LanguageManager.shared.currentLanguage
        return string(for: key, language: lang)
    }

    /// Translates a key for an explicit AppLanguage. Falls back to English.
    public static func string(for key: String, language: AppLanguage) -> String {
        if let langDict = translations[language], let value = langDict[key] {
            return value
        }
        // Fallback to English
        if let enDict = translations[.english], let fallback = enDict[key] {
            return fallback
        }
        return key
    }

    // MARK: - Translation Matrix
    private static let translations: [AppLanguage: [String: String]] = [
        // 🇬🇧 English
        .english: [
            // Sidebar / Navigation
            "Search": "Search",
            "Home": "Home",
            "Movies": "Movies",
            "TV Shows": "TV Shows",
            "Trending": "Trending",
            "Watchlist": "Watchlist",
            "Collections": "Collections",
            "History": "History",
            "Downloads": "Downloads",
            "Browse": "Browse",
            "Library": "Library",
            
            // Rails
            "Continue Watching": "Continue Watching",
            "Trending Today": "Trending Today",
            "Trending This Week": "Trending This Week",
            "Popular Movies": "Popular Movies",
            "Popular TV Shows": "Popular TV Shows",
            "Top Rated": "Top Rated",
            "Top Rated Movies": "Top Rated Movies",
            "Top Rated Shows": "Top Rated Shows",
            "Popular on Streaming": "Popular on Streaming",
            "Animated Adventures": "Animated Adventures",
            "Kids Shows": "Kids Shows",
            "Family Movie Night": "Family Movie Night",
            "Quick Watches": "Quick Watches",
            "Quick Watches (< 95m)": "Quick Watches (< 95m)",
            "Airing Today": "Airing Today",
            "On The Air": "On The Air",
            "On TV": "On TV",
            "Now Playing": "Now Playing",
            "Upcoming": "Upcoming",
            "Trending for Kids": "Trending for Kids",
            "Recently Watched": "Recently Watched",
            "Explore": "Explore",
            "Browse by Genre": "Browse by Genre",
            "Browse for Kids": "Browse for Kids",
            "Trending Movies Today": "Trending Movies Today",
            "Trending Movies This Week": "Trending Movies This Week",
            "Trending Shows Today": "Trending Shows Today",
            "Trending Shows This Week": "Trending Shows This Week",
            
            // Details & Player
            "Play": "Play",
            "Resume": "Resume",
            "Start Over": "Start Over",
            "Watch Trailer": "Watch Trailer",
            "Add to Watchlist": "Add to Watchlist",
            "In Watchlist": "In Watchlist",
            "Overview": "Overview",
            "Episodes": "Episodes",
            "Cast & Crew": "Cast & Crew",
            "Similar": "Similar",
            "Recommendations": "Recommendations",
            "Season": "Season",
            "Episode": "Episode",
            "Streams": "Streams",
            "Next Episode": "Next Episode",
            "Subtitles": "Subtitles",
            "Audio Track": "Audio Track",
            "Speed": "Speed",
            "Close": "Close",
            "Auto-Playing": "Auto-Playing",
            "Seeders": "Seeders",
            "Quality": "Quality",
            
            // Collections & History
            "New Collection": "New Collection",
            "Empty Watchlist": "Empty Watchlist",
            "In Progress": "In Progress",
            "Completed": "Completed",
            "Clear History": "Clear History",
            
            // Settings
            "Settings": "Settings",
            "General": "General",
            "Streaming": "Streaming",
            "Addons": "Addons",
            "Playback": "Playback",
            "Advanced": "Advanced",
            "Account": "Account",
            "Watching Profiles": "Watching Profiles",
            "Manage Profiles…": "Manage Profiles…",
            "Catalog & Metadata": "Catalog & Metadata",
            "App Language": "App Language",
            "Select Interface Language": "Select your preferred application interface and metadata language.",
            "App Information": "App Information",
            "Version": "Version",
            "Stream Sources": "Stream Sources",
            "Stream Filter": "Stream Filter",
            "Flux Mode": "Flux Mode",
            "Enable Flux Mode": "Enable Flux Mode",
            "Maximum Resolution": "Maximum Resolution",
            "Language Filter in Flux Mode": "Language Filter in Flux Mode",
            "Video Player": "Video Player",
            "Hardware Acceleration": "Hardware Acceleration",
            "Playback Behavior": "Playback Behavior",
            "Auto-play Next Episode": "Auto-play Next Episode",
            "Audio": "Audio",
            "Audio Passthrough (Atmos / DTS)": "Audio Passthrough (Atmos / DTS)",
            "Languages": "Languages",
            "Default Audio": "Default Audio",
            "Default Subtitles": "Default Subtitles",
            "Sign In": "Sign In",
            "Sign Out": "Sign Out",
            "Sync Now": "Sync Now",
            "Cloud Sync": "Cloud Sync"
        ],

        // 🇯🇵 Japanese
        .japanese: [
            "Search": "検索",
            "Home": "ホーム",
            "Movies": "映画",
            "TV Shows": "テレビ番組",
            "Trending": "急上昇",
            "Watchlist": "マイリスト",
            "Collections": "コレクション",
            "History": "視聴履歴",
            "Downloads": "ダウンロード",
            "Browse": "ブラウズ",
            "Library": "ライブラリ",
            
            "Continue Watching": "続きを見る",
            "Trending Today": "今日の急上昇",
            "Trending This Week": "今週の急上昇",
            "Popular Movies": "人気の映画",
            "Popular TV Shows": "人気のテレビ番組",
            "Top Rated": "高評価の作品",
            "Top Rated Movies": "高評価の映画",
            "Top Rated Shows": "高評価の番組",
            "Popular on Streaming": "配信で人気",
            "Animated Adventures": "アニメーション",
            "Kids Shows": "キッズ向け番組",
            "Family Movie Night": "ファミリー向け映画",
            "Quick Watches": "手軽に見られる作品",
            "Quick Watches (< 95m)": "サクッと観られる作品 (< 95分)",
            "Airing Today": "本日放送",
            "On The Air": "放送中",
            "On TV": "テレビ放送中",
            "Now Playing": "上映中",
            "Upcoming": "公開予定",
            "Trending for Kids": "キッズ向けトレンド",
            "Recently Watched": "最近再生した作品",
            "Explore": "見つける",
            "Browse by Genre": "ジャンルから探す",
            "Browse for Kids": "キッズ向け作品",
            "Trending Movies Today": "今日のトレンド映画",
            "Trending Movies This Week": "今週のトレンド映画",
            "Trending Shows Today": "今日のトレンド番組",
            "Trending Shows This Week": "今週のトレンド番組",
            
            "Play": "再生",
            "Resume": "再開",
            "Start Over": "最初から再生",
            "Watch Trailer": "予告編を見る",
            "Add to Watchlist": "マイリストに追加",
            "In Watchlist": "マイリストに追加済み",
            "Overview": "概要",
            "Episodes": "エピソード",
            "Cast & Crew": "キャスト・スタッフ",
            "Similar": "似た作品",
            "Recommendations": "おすすめ",
            "Season": "シーズン",
            "Episode": "エピソード",
            "Streams": "ストリーム",
            "Next Episode": "次のエピソード",
            "Subtitles": "字幕",
            "Audio Track": "音声トラック",
            "Speed": "再生速度",
            "Close": "閉じる",
            "Auto-Playing": "自動再生中",
            "Seeders": "シーダー",
            "Quality": "画質",
            
            "New Collection": "新しいコレクション",
            "Empty Watchlist": "マイリストは空です",
            "In Progress": "視聴中",
            "Completed": "視聴完了",
            "Clear History": "履歴を消去",
            
            "Settings": "設定",
            "General": "一般",
            "Streaming": "配信設定",
            "Addons": "アドオン",
            "Playback": "再生設定",
            "Advanced": "詳細設定",
            "Account": "アカウント",
            "Watching Profiles": "プロフィール",
            "Manage Profiles…": "プロフィール管理…",
            "Catalog & Metadata": "カタログとメタデータ",
            "App Language": "アプリの言語",
            "Select Interface Language": "アプリのインターフェースおよびメタデータの表示言語を選択します。",
            "App Information": "アプリ情報",
            "Version": "バージョン",
            "Stream Sources": "配信ソース",
            "Stream Filter": "ストリームフィルター",
            "Flux Mode": "Flux モード",
            "Enable Flux Mode": "Flux モードを有効にする",
            "Maximum Resolution": "最大解像度",
            "Language Filter in Flux Mode": "Flux モードでの言語フィルター",
            "Video Player": "動画プレイヤー",
            "Hardware Acceleration": "ハードウェアアクセラレーション",
            "Playback Behavior": "再生の動作",
            "Auto-play Next Episode": "次のエピソードを自動再生",
            "Audio": "音声",
            "Audio Passthrough (Atmos / DTS)": "音声パススルー (Atmos / DTS)",
            "Languages": "言語",
            "Default Audio": "デフォルト音声",
            "Default Subtitles": "デフォルト字幕",
            "Sign In": "サインイン",
            "Sign Out": "サインアウト",
            "Sync Now": "今すぐ同期",
            "Cloud Sync": "クラウド同期"
        ],

        // 🇪🇸 Spanish
        .spanish: [
            "Search": "Buscar",
            "Home": "Inicio",
            "Movies": "Películas",
            "TV Shows": "Series",
            "Trending": "Tendencias",
            "Watchlist": "Mi Lista",
            "Collections": "Colecciones",
            "History": "Historial",
            "Downloads": "Descargas",
            "Browse": "Explorar",
            "Library": "Biblioteca",
            
            "Continue Watching": "Continuar viendo",
            "Trending Today": "Tendencias de hoy",
            "Trending This Week": "Tendencias de la semana",
            "Popular Movies": "Películas populares",
            "Popular TV Shows": "Series populares",
            "Top Rated": "Mejor valoradas",
            "Top Rated Movies": "Películas mejor valoradas",
            "Top Rated Shows": "Series mejor valoradas",
            "Popular on Streaming": "Popular en streaming",
            "Animated Adventures": "Aventuras animadas",
            "Kids Shows": "Programas infantiles",
            "Family Movie Night": "Noche de cine familiar",
            "Quick Watches": "Para ver rápido",
            "Quick Watches (< 95m)": "Películas cortas (< 95 min)",
            "Airing Today": "Se emiten hoy",
            "On The Air": "En emisión",
            "On TV": "En televisión",
            "Now Playing": "En cartelera",
            "Upcoming": "Próximamente",
            "Trending for Kids": "Tendencias para niños",
            "Recently Watched": "Visto recientemente",
            "Explore": "Explorar",
            "Browse by Genre": "Explorar por género",
            "Browse for Kids": "Para niños",
            "Trending Movies Today": "Películas en tendencia hoy",
            "Trending Movies This Week": "Películas en tendencia esta semana",
            "Trending Shows Today": "Series en tendencia hoy",
            "Trending Shows This Week": "Series en tendencia esta semana",
            
            "Play": "Reproducir",
            "Resume": "Reanudar",
            "Start Over": "Reiniciar",
            "Watch Trailer": "Ver tráiler",
            "Add to Watchlist": "Añadir a mi lista",
            "In Watchlist": "En mi lista",
            "Overview": "Sinopsis",
            "Episodes": "Episodios",
            "Cast & Crew": "Reparto y equipo",
            "Similar": "Similares",
            "Recommendations": "Recomendaciones",
            "Season": "Temporada",
            "Episode": "Episodio",
            "Streams": "Fuentes",
            "Next Episode": "Siguiente episodio",
            "Subtitles": "Subtítulos",
            "Audio Track": "Pista de audio",
            "Speed": "Velocidad",
            "Close": "Cerrar",
            "Auto-Playing": "Reproduciendo automáticamente",
            "Seeders": "Semillas",
            "Quality": "Calidad",
            
            "New Collection": "Nueva colección",
            "Empty Watchlist": "Lista vacía",
            "In Progress": "En curso",
            "Completed": "Completado",
            "Clear History": "Borrar historial",
            
            "Settings": "Ajustes",
            "General": "General",
            "Streaming": "Transmisión",
            "Addons": "Complementos",
            "Playback": "Reproducción",
            "Advanced": "Avanzado",
            "Account": "Cuenta",
            "Watching Profiles": "Perfiles",
            "Manage Profiles…": "Gestionar perfiles…",
            "Catalog & Metadata": "Catálogo y metadatos",
            "App Language": "Idioma de la aplicación",
            "Select Interface Language": "Selecciona tu idioma preferido para la interfaz y los metadatos.",
            "App Information": "Información de la aplicación",
            "Version": "Versión",
            "Stream Sources": "Fuentes de transmisión",
            "Stream Filter": "Filtro de fuentes",
            "Flux Mode": "Modo Flux",
            "Enable Flux Mode": "Activar Modo Flux",
            "Maximum Resolution": "Resolución máxima",
            "Language Filter in Flux Mode": "Filtro de idioma en Modo Flux",
            "Video Player": "Reproductor de vídeo",
            "Hardware Acceleration": "Aceleración por hardware",
            "Playback Behavior": "Comportamiento de reproducción",
            "Auto-play Next Episode": "Reproducir siguiente episodio automáticamente",
            "Audio": "Audio",
            "Audio Passthrough (Atmos / DTS)": "Passthrough de audio (Atmos / DTS)",
            "Languages": "Idiomas",
            "Default Audio": "Audio predeterminado",
            "Default Subtitles": "Subtítulos predeterminados",
            "Sign In": "Iniciar sesión",
            "Sign Out": "Cerrar sesión",
            "Sync Now": "Sincronizar ahora",
            "Cloud Sync": "Sincronización en la nube"
        ],

        // 🇫🇷 French
        .french: [
            "Search": "Recherche",
            "Home": "Accueil",
            "Movies": "Films",
            "TV Shows": "Séries",
            "Trending": "Tendances",
            "Watchlist": "Ma Liste",
            "Collections": "Collections",
            "History": "Historique",
            "Downloads": "Téléchargements",
            "Browse": "Parcourir",
            "Library": "Bibliothèque",
            
            "Continue Watching": "Reprendre la lecture",
            "Trending Today": "Tendances du jour",
            "Trending This Week": "Tendances de la semaine",
            "Popular Movies": "Films populaires",
            "Popular TV Shows": "Séries populaires",
            "Top Rated": "Les mieux notés",
            "Top Rated Movies": "Films les mieux notés",
            "Top Rated Shows": "Séries les mieux notées",
            "Popular on Streaming": "Populaire en streaming",
            "Animated Adventures": "Aventures animées",
            "Kids Shows": "Programmes jeunesse",
            "Family Movie Night": "Soirée cinéma en famille",
            "Quick Watches": "Visionnages rapides",
            "Quick Watches (< 95m)": "Films courts (< 95 min)",
            "Airing Today": "Diffusés aujourd'hui",
            "On The Air": "En cours de diffusion",
            "On TV": "À la télévision",
            "Now Playing": "À l'affiche",
            "Upcoming": "Prochainement",
            "Trending for Kids": "Tendances pour enfants",
            "Recently Watched": "Visionnés récemment",
            "Explore": "Explorer",
            "Browse by Genre": "Parcourir par genre",
            "Browse for Kids": "Pour les enfants",
            "Trending Movies Today": "Films tendance aujourd'hui",
            "Trending Movies This Week": "Films tendance cette semaine",
            "Trending Shows Today": "Séries tendance aujourd'hui",
            "Trending Shows This Week": "Séries tendance cette semaine",
            
            "Play": "Lire",
            "Resume": "Reprendre",
            "Start Over": "Recommencer",
            "Watch Trailer": "Voir la bande-annonce",
            "Add to Watchlist": "Ajouter à ma liste",
            "In Watchlist": "Dans ma liste",
            "Overview": "Synopsis",
            "Episodes": "Épisodes",
            "Cast & Crew": "Distribution et équipe",
            "Similar": "Titres similaires",
            "Recommendations": "Recommandations",
            "Season": "Saison",
            "Episode": "Épisode",
            "Streams": "Flux",
            "Next Episode": "Épisode suivant",
            "Subtitles": "Sous-titres",
            "Audio Track": "Piste audio",
            "Speed": "Vitesse",
            "Close": "Fermer",
            "Auto-Playing": "Lecture automatique",
            "Seeders": "Partages",
            "Quality": "Qualité",
            
            "New Collection": "Nouvelle collection",
            "Empty Watchlist": "Liste vide",
            "In Progress": "En cours",
            "Completed": "Terminé",
            "Clear History": "Effacer l'historique",
            
            "Settings": "Réglages",
            "General": "Général",
            "Streaming": "Streaming",
            "Addons": "Extensions",
            "Playback": "Lecture",
            "Advanced": "Avancé",
            "Account": "Compte",
            "Watching Profiles": "Profils de visionnage",
            "Manage Profiles…": "Gérer les profils…",
            "Catalog & Metadata": "Catalogue et métadonnées",
            "App Language": "Langue de l'application",
            "Select Interface Language": "Sélectionnez votre langue d'interface et de métadonnées préférée.",
            "App Information": "Informations sur l'application",
            "Version": "Version",
            "Stream Sources": "Sources de streaming",
            "Stream Filter": "Filtre de sources",
            "Flux Mode": "Mode Flux",
            "Enable Flux Mode": "Activer le Mode Flux",
            "Maximum Resolution": "Résolution maximale",
            "Language Filter in Flux Mode": "Filtre de langue en Mode Flux",
            "Video Player": "Lecteur vidéo",
            "Hardware Acceleration": "Accélération matérielle",
            "Playback Behavior": "Comportement de lecture",
            "Auto-play Next Episode": "Lire l'épisode suivant automatiquement",
            "Audio": "Audio",
            "Audio Passthrough (Atmos / DTS)": "Passthrough audio (Atmos / DTS)",
            "Languages": "Langues",
            "Default Audio": "Audio par défaut",
            "Default Subtitles": "Sous-titres par défaut",
            "Sign In": "Se connecter",
            "Sign Out": "Se déconnecter",
            "Sync Now": "Synchroniser maintenant",
            "Cloud Sync": "Synchronisation cloud"
        ],

        // 🇩🇪 German
        .german: [
            "Search": "Suche",
            "Home": "Startseite",
            "Movies": "Filme",
            "TV Shows": "Serien",
            "Trending": "Angesagt",
            "Watchlist": "Merkliste",
            "Collections": "Sammlungen",
            "History": "Verlauf",
            "Downloads": "Downloads",
            "Browse": "Entdecken",
            "Library": "Mediathek",
            
            "Continue Watching": "Weiterschauen",
            "Trending Today": "Heute im Trend",
            "Trending This Week": "Diese Woche im Trend",
            "Popular Movies": "Beliebte Filme",
            "Popular TV Shows": "Beliebte Serien",
            "Top Rated": "Top-Bewertungen",
            "Top Rated Movies": "Bestbewertete Filme",
            "Top Rated Shows": "Bestbewertete Serien",
            "Popular on Streaming": "Beliebt im Streaming",
            "Animated Adventures": "Animationsabenteuer",
            "Kids Shows": "Kinderserien",
            "Family Movie Night": "Familienfilmabend",
            "Quick Watches": "Kurze Unterhaltung",
            "Quick Watches (< 95m)": "Kurze Filme (< 95 Min.)",
            "Airing Today": "Heute im TV",
            "On The Air": "Aktuell im TV",
            "On TV": "Im Fernsehen",
            "Now Playing": "Jetzt im Kino",
            "Upcoming": "Demnächst",
            "Trending for Kids": "Trends für Kinder",
            "Recently Watched": "Zuletzt gesehen",
            "Explore": "Entdecken",
            "Browse by Genre": "Nach Genre durchsuchen",
            "Browse for Kids": "Für Kinder",
            "Trending Movies Today": "Heute im Trend (Filme)",
            "Trending Movies This Week": "Diese Woche im Trend (Filme)",
            "Trending Shows Today": "Heute im Trend (Serien)",
            "Trending Shows This Week": "Diese Woche im Trend (Serien)",
            
            "Play": "Abspielen",
            "Resume": "Fortsetzen",
            "Start Over": "Von Beginn an",
            "Watch Trailer": "Trailer ansehen",
            "Add to Watchlist": "Zur Merkliste hinzufügen",
            "In Watchlist": "Auf der Merkliste",
            "Overview": "Übersicht",
            "Episodes": "Episoden",
            "Cast & Crew": "Besetzung & Team",
            "Similar": "Ähnliche Titel",
            "Recommendations": "Empfehlungen",
            "Season": "Staffel",
            "Episode": "Episode",
            "Streams": "Streams",
            "Next Episode": "Nächste Episode",
            "Subtitles": "Untertitel",
            "Audio Track": "Tonspur",
            "Speed": "Geschwindigkeit",
            "Close": "Schließen",
            "Auto-Playing": "Automatische Wiedergabe",
            "Seeders": "Seeder",
            "Quality": "Qualität",
            
            "New Collection": "Neue Sammlung",
            "Empty Watchlist": "Merkliste ist leer",
            "In Progress": "In Wiedergabe",
            "Completed": "Abgeschlossen",
            "Clear History": "Verlauf löschen",
            
            "Settings": "Einstellungen",
            "General": "Allgemein",
            "Streaming": "Streaming",
            "Addons": "Erweiterungen",
            "Playback": "Wiedergabe",
            "Advanced": "Erweitert",
            "Account": "Konto",
            "Watching Profiles": "Nutzerprofile",
            "Manage Profiles…": "Profile verwalten…",
            "Catalog & Metadata": "Katalog & Metadaten",
            "App Language": "App-Sprache",
            "Select Interface Language": "Wählen Sie Ihre bevorzugte Sprache für Benutzeroberfläche und Metadaten.",
            "App Information": "App-Informationen",
            "Version": "Version",
            "Stream Sources": "Stream-Quellen",
            "Stream Filter": "Stream-Filter",
            "Flux Mode": "Flux-Modus",
            "Enable Flux Mode": "Flux-Modus aktivieren",
            "Maximum Resolution": "Maximale Auflösung",
            "Language Filter in Flux Mode": "Sprachfilter im Flux-Modus",
            "Video Player": "Videoplayer",
            "Hardware Acceleration": "Hardwarebeschleunigung",
            "Playback Behavior": "Wiedergabeverhalten",
            "Auto-play Next Episode": "Nächste Episode automatisch abspielen",
            "Audio": "Audio",
            "Audio Passthrough (Atmos / DTS)": "Audio-Passthrough (Atmos / DTS)",
            "Languages": "Sprachen",
            "Default Audio": "Standard-Audiosprache",
            "Default Subtitles": "Standard-Untertitel",
            "Sign In": "Anmelden",
            "Sign Out": "Abmelden",
            "Sync Now": "Jetzt synchronisieren",
            "Cloud Sync": "Cloud-Synchronisation"
        ],

        // 🇮🇹 Italian
        .italian: [
            "Search": "Cerca",
            "Home": "Home",
            "Movies": "Film",
            "TV Shows": "Serie TV",
            "Trending": "Tendenze",
            "Watchlist": "La mia lista",
            "Collections": "Raccolte",
            "History": "Cronologia",
            "Downloads": "Download",
            "Browse": "Esplora",
            "Library": "Libreria",
            
            "Continue Watching": "Continua a guardare",
            "Trending Today": "Tendenze di oggi",
            "Trending This Week": "Tendenze della settimana",
            "Popular Movies": "Film popolari",
            "Popular TV Shows": "Serie TV popolari",
            "Top Rated": "I più votati",
            "Top Rated Movies": "Film più votati",
            "Top Rated Shows": "Serie più votate",
            "Popular on Streaming": "Popolari in streaming",
            "Animated Adventures": "Animazione",
            "Kids Shows": "Programmi per bambini",
            "Family Movie Night": "Cinema in famiglia",
            "Quick Watches": "Visioni veloci",
            "Quick Watches (< 95m)": "Visione veloce (< 95 min)",
            "Airing Today": "In onda oggi",
            "On The Air": "In trasmissione",
            "On TV": "In TV",
            "Now Playing": "Al cinema",
            "Upcoming": "In arrivo",
            "Trending for Kids": "Tendenze per bambini",
            "Recently Watched": "Visti di recente",
            "Explore": "Esplora",
            "Browse by Genre": "Sfoglia per genere",
            "Browse for Kids": "Per bambini",
            "Trending Movies Today": "Film del momento oggi",
            "Trending Movies This Week": "Film del momento questa settimana",
            "Trending Shows Today": "Serie del momento oggi",
            "Trending Shows This Week": "Serie del momento questa settimana",
            
            "Play": "Riproduci",
            "Resume": "Riprendi",
            "Start Over": "Ricomincia",
            "Watch Trailer": "Guarda il trailer",
            "Add to Watchlist": "Aggiungi alla lista",
            "In Watchlist": "Nella lista",
            "Overview": "Trama",
            "Episodes": "Episodi",
            "Cast & Crew": "Cast e troupe",
            "Similar": "Simili",
            "Recommendations": "Consigliati",
            "Season": "Stagione",
            "Episode": "Episodio",
            "Streams": "Flussi",
            "Next Episode": "Episodio successivo",
            "Subtitles": "Sottotitoli",
            "Audio Track": "Traccia audio",
            "Speed": "Velocità",
            "Close": "Chiudi",
            "Auto-Playing": "Riproduzione automatica",
            "Seeders": "Seeder",
            "Quality": "Qualità",
            
            "New Collection": "Nuova raccolta",
            "Empty Watchlist": "Lista vuota",
            "In Progress": "In corso",
            "Completed": "Completato",
            "Clear History": "Cancella cronologia",
            
            "Settings": "Impostazioni",
            "General": "Generale",
            "Streaming": "Streaming",
            "Addons": "Estensioni",
            "Playback": "Riproduzione",
            "Advanced": "Avanzate",
            "Account": "Account",
            "Watching Profiles": "Profili",
            "Manage Profiles…": "Gestisci profili…",
            "Catalog & Metadata": "Catalogo e metadati",
            "App Language": "Lingua dell'app",
            "Select Interface Language": "Seleziona la lingua per l'interfaccia e i metadati.",
            "App Information": "Informazioni sull'app",
            "Version": "Versione",
            "Stream Sources": "Sorgenti di streaming",
            "Stream Filter": "Filtro sorgenti",
            "Flux Mode": "Modalità Flux",
            "Enable Flux Mode": "Attiva Modalità Flux",
            "Maximum Resolution": "Risoluzione massima",
            "Language Filter in Flux Mode": "Filtro lingua in Modalità Flux",
            "Video Player": "Lettore video",
            "Hardware Acceleration": "Accelerazione hardware",
            "Playback Behavior": "Comportamento di riproduzione",
            "Auto-play Next Episode": "Riproduci automaticamente episodio successivo",
            "Audio": "Audio",
            "Audio Passthrough (Atmos / DTS)": "Passthrough audio (Atmos / DTS)",
            "Languages": "Lingue",
            "Default Audio": "Audio predefinito",
            "Default Subtitles": "Sottotitoli predefiniti",
            "Sign In": "Accedi",
            "Sign Out": "Esci",
            "Sync Now": "Sincronizza ora",
            "Cloud Sync": "Sincronizzazione cloud"
        ],

        // 🇧🇷 Portuguese
        .portuguese: [
            "Search": "Buscar",
            "Home": "Início",
            "Movies": "Filmes",
            "TV Shows": "Séries",
            "Trending": "Em alta",
            "Watchlist": "Minha Lista",
            "Collections": "Coleções",
            "History": "Histórico",
            "Downloads": "Downloads",
            "Browse": "Navegar",
            "Library": "Biblioteca",
            
            "Continue Watching": "Continuar assistindo",
            "Trending Today": "Em alta hoje",
            "Trending This Week": "Em alta esta semana",
            "Popular Movies": "Filmes populares",
            "Popular TV Shows": "Séries populares",
            "Top Rated": "Mais bem avaliados",
            "Top Rated Movies": "Filmes mais bem avaliados",
            "Top Rated Shows": "Séries mais bem avaliadas",
            "Popular on Streaming": "Populares no streaming",
            "Animated Adventures": "Aventuras animadas",
            "Kids Shows": "Programas infantis",
            "Family Movie Night": "Noite de cinema em família",
            "Quick Watches": "Para assistir rápido",
            "Quick Watches (< 95m)": "Filmes curtos (< 95 min)",
            "Airing Today": "Exibidos hoje",
            "On The Air": "No ar",
            "On TV": "Na TV",
            "Now Playing": "Em cartaz",
            "Upcoming": "Em breve",
            "Trending for Kids": "Em alta para crianças",
            "Recently Watched": "Assistidos recentemente",
            "Explore": "Explorar",
            "Browse by Genre": "Navegar por gênero",
            "Browse for Kids": "Para crianças",
            "Trending Movies Today": "Filmes em alta hoje",
            "Trending Movies This Week": "Filmes em alta esta semana",
            "Trending Shows Today": "Séries em alta hoje",
            "Trending Shows This Week": "Séries em alta esta semana",
            
            "Play": "Assistir",
            "Resume": "Continuar",
            "Start Over": "Recomeçar",
            "Watch Trailer": "Ver trailer",
            "Add to Watchlist": "Adicionar à Minha Lista",
            "In Watchlist": "Na Minha Lista",
            "Overview": "Sinopse",
            "Episodes": "Episódios",
            "Cast & Crew": "Elenco e equipe",
            "Similar": "Títulos semelhantes",
            "Recommendations": "Recomendações",
            "Season": "Temporada",
            "Episode": "Episódio",
            "Streams": "Transmissões",
            "Next Episode": "Próximo episódio",
            "Subtitles": "Legendas",
            "Audio Track": "Faixa de áudio",
            "Speed": "Velocidade",
            "Close": "Fechar",
            "Auto-Playing": "Reprodução automática",
            "Seeders": "Seeders",
            "Quality": "Qualidade",
            
            "New Collection": "Nova coleção",
            "Empty Watchlist": "Sua lista está vazia",
            "In Progress": "Em andamento",
            "Completed": "Concluído",
            "Clear History": "Limpar histórico",
            
            "Settings": "Ajustes",
            "General": "Geral",
            "Streaming": "Transmissão",
            "Addons": "Extensões",
            "Playback": "Reprodução",
            "Advanced": "Avançado",
            "Account": "Conta",
            "Watching Profiles": "Perfis",
            "Manage Profiles…": "Gerenciar perfis…",
            "Catalog & Metadata": "Catálogo e metadados",
            "App Language": "Idioma do aplicativo",
            "Select Interface Language": "Selecione o idioma de sua preferência para a interface e metadados.",
            "App Information": "Informações do aplicativo",
            "Version": "Versão",
            "Stream Sources": "Fontes de transmissão",
            "Stream Filter": "Filtro de fontes",
            "Flux Mode": "Modo Flux",
            "Enable Flux Mode": "Ativar Modo Flux",
            "Maximum Resolution": "Resolução máxima",
            "Language Filter in Flux Mode": "Filtro de idioma no Modo Flux",
            "Video Player": "Reprodutor de vídeo",
            "Hardware Acceleration": "Aceleração por hardware",
            "Playback Behavior": "Comportamento de reprodução",
            "Auto-play Next Episode": "Reproduzir próximo episódio automaticamente",
            "Audio": "Áudio",
            "Audio Passthrough (Atmos / DTS)": "Passthrough de áudio (Atmos / DTS)",
            "Languages": "Idiomas",
            "Default Audio": "Áudio padrão",
            "Default Subtitles": "Legendas padrão",
            "Sign In": "Entrar",
            "Sign Out": "Sair",
            "Sync Now": "Sincronizar agora",
            "Cloud Sync": "Sincronização em nuvem"
        ],

        // 🇰🇷 Korean
        .korean: [
            "Search": "검색",
            "Home": "홈",
            "Movies": "영화",
            "TV Shows": "TV 프로그램",
            "Trending": "인기 급상승",
            "Watchlist": "보관함",
            "Collections": "컬렉션",
            "History": "시청 기록",
            "Downloads": "다운로드",
            "Browse": "둘러보기",
            "Library": "라이브러리",
            
            "Continue Watching": "이어보기",
            "Trending Today": "오늘의 트렌드",
            "Trending This Week": "이번 주 트렌드",
            "Popular Movies": "인기 영화",
            "Popular TV Shows": "인기 TV 프로그램",
            "Top Rated": "최고 평점",
            "Top Rated Movies": "최고 평점 영화",
            "Top Rated Shows": "최고 평점 시리즈",
            "Popular on Streaming": "스트리밍 인기작",
            "Animated Adventures": "애니메이션",
            "Kids Shows": "어린이 프로그램",
            "Family Movie Night": "가족 영화",
            "Quick Watches": "짧은 영상",
            "Quick Watches (< 95m)": "부담 없이 보는 영화 (< 95분)",
            "Airing Today": "오늘 방영",
            "On The Air": "현재 방영 중",
            "On TV": "현재 방송 중",
            "Now Playing": "현재 상영 중",
            "Upcoming": "개봉 예정",
            "Trending for Kids": "어린이 인기작",
            "Recently Watched": "최근 시청한 콘텐츠",
            "Explore": "탐색",
            "Browse by Genre": "장르별 탐색",
            "Browse for Kids": "키즈 추천",
            "Trending Movies Today": "오늘의 인기 영화",
            "Trending Movies This Week": "이번 주 인기 영화",
            "Trending Shows Today": "오늘의 인기 시리즈",
            "Trending Shows This Week": "이번 주 인기 시리즈",
            
            "Play": "재생",
            "Resume": "이어보기",
            "Start Over": "처음부터",
            "Watch Trailer": "예고편 보기",
            "Add to Watchlist": "보관함에 추가",
            "In Watchlist": "보관함에 저장됨",
            "Overview": "줄거리",
            "Episodes": "에피소드",
            "Cast & Crew": "출연진 및 제작진",
            "Similar": "비슷한 콘텐츠",
            "Recommendations": "추천 콘텐츠",
            "Season": "시즌",
            "Episode": "화",
            "Streams": "스트림",
            "Next Episode": "다음 에피소드",
            "Subtitles": "자막",
            "Audio Track": "오디오 트랙",
            "Speed": "재생 속도",
            "Close": "닫기",
            "Auto-Playing": "자동 재생 중",
            "Seeders": "시더",
            "Quality": "화질",
            
            "New Collection": "새 컬렉션",
            "Empty Watchlist": "보관함이 비어 있습니다",
            "In Progress": "시청 중",
            "Completed": "시청 완료",
            "Clear History": "기록 삭제",
            
            "Settings": "설정",
            "General": "일반",
            "Streaming": "스트리밍",
            "Addons": "부가기능",
            "Playback": "재생",
            "Advanced": "고급",
            "Account": "계정",
            "Watching Profiles": "프로필",
            "Manage Profiles…": "프로필 관리…",
            "Catalog & Metadata": "카탈로그 및 메타데이터",
            "App Language": "앱 언어",
            "Select Interface Language": "선호하는 인터페이스 및 메타데이터 언어를 선택하세요.",
            "App Information": "앱 정보",
            "Version": "버전",
            "Stream Sources": "스트림 소스",
            "Stream Filter": "스트림 필터",
            "Flux Mode": "Flux 모드",
            "Enable Flux Mode": "Flux 모드 활성화",
            "Maximum Resolution": "최대 해상도",
            "Language Filter in Flux Mode": "Flux 모드 언어 필터",
            "Video Player": "비디오 플레이어",
            "Hardware Acceleration": "하드웨어 가속",
            "Playback Behavior": "재생 동작",
            "Auto-play Next Episode": "다음 화 자동 재생",
            "Audio": "오디오",
            "Audio Passthrough (Atmos / DTS)": "오디오 패스스루 (Atmos / DTS)",
            "Languages": "언어",
            "Default Audio": "기본 오디오",
            "Default Subtitles": "기본 자막",
            "Sign In": "로그인",
            "Sign Out": "로그아웃",
            "Sync Now": "지금 동기화",
            "Cloud Sync": "클라우드 동기화"
        ],

        // 🇮🇳 Hindi
        .hindi: [
            "Search": "खोजें",
            "Home": "होम",
            "Movies": "फ़िल्में",
            "TV Shows": "टीवी शो",
            "Trending": "ट्रेंडिंग",
            "Watchlist": "मेरी सूची",
            "Collections": "संग्रह",
            "History": "इतिहास",
            "Downloads": "डाउनलोड",
            "Browse": "ब्राउज़ करें",
            "Library": "लाइब्रेरी",
            
            "Continue Watching": "आगे देखें",
            "Trending Today": "आज का ट्रेंडिंग",
            "Trending This Week": "इस हफ़्ते का ट्रेंडिंग",
            "Popular Movies": "लोकप्रिय फ़िल्में",
            "Popular TV Shows": "लोकप्रिय टीवी शो",
            "Top Rated": "टॉप रेटेड",
            "Top Rated Movies": "शीर्ष रेटेड फिल्में",
            "Top Rated Shows": "शीर्ष रेटेड शो",
            "Popular on Streaming": "स्ट्रीमिंग पर लोकप्रिय",
            "Animated Adventures": "एनीमेशन",
            "Kids Shows": "बच्चों के शो",
            "Family Movie Night": "पारिवारिक फ़िल्में",
            "Quick Watches": "तुरंत देखने योग्य",
            "Quick Watches (< 95m)": "त्वरित फिल्में (< 95 मिनट)",
            "Airing Today": "आज प्रसारित",
            "On The Air": "प्रसारित हो रहे हैं",
            "On TV": "टीवी पर प्रसारण",
            "Now Playing": "अब सिनेमाघरों में",
            "Upcoming": "आने वाले",
            "Trending for Kids": "बच्चों के लिए ट्रेंडिंग",
            "Recently Watched": "हाल ही में देखा गया",
            "Explore": "खोजें",
            "Browse by Genre": "शैली के अनुसार खोजें",
            "Browse for Kids": "बच्चों के लिए",
            "Trending Movies Today": "आज की ट्रेंडिंग फिल्में",
            "Trending Movies This Week": "इस सप्ताह की ट्रेंडिंग फिल्में",
            "Trending Shows Today": "आज के ट्रेंडिंग शो",
            "Trending Shows This Week": "इस सप्ताह के ट्रेंडिंग शो",
            
            "Play": "चलाएं",
            "Resume": "फिर शुरू करें",
            "Start Over": "शुरू से देखें",
            "Watch Trailer": "ट्रेलर देखें",
            "Add to Watchlist": "सूची में जोड़ें",
            "In Watchlist": "सूची में है",
            "Overview": "सारांश",
            "Episodes": "एपिसोड",
            "Cast & Crew": "कलाकार और क्रू",
            "Similar": "समान शीर्षक",
            "Recommendations": "सिफारिशें",
            "Season": "सीज़न",
            "Episode": "एपिसोड",
            "Streams": "स्ट्रीम",
            "Next Episode": "अगला एपिसोड",
            "Subtitles": "उपशीर्षक",
            "Audio Track": "ऑडियो ट्रैक",
            "Speed": "गति",
            "Close": "बंद करें",
            "Auto-Playing": "स्वतः चल रहा है",
            "Seeders": "सीडर्स",
            "Quality": "गुणवत्ता",
            
            "New Collection": "नया संग्रह",
            "Empty Watchlist": "आपकी सूची खाली है",
            "In Progress": "प्रगति में",
            "Completed": "पूरा हुआ",
            "Clear History": "इतिहास मिटाएं",
            
            "Settings": "सेटिंग्स",
            "General": "सामान्य",
            "Streaming": "स्ट्रीमिंग",
            "Addons": "ऐड-ऑन",
            "Playback": "प्लेबैक",
            "Advanced": "उन्नत",
            "Account": "खाता",
            "Watching Profiles": "प्रोफाइल",
            "Manage Profiles…": "प्रोफाइल प्रबंधित करें…",
            "Catalog & Metadata": "कैटलॉग और मेटाडेटा",
            "App Language": "ऐप की भाषा",
            "Select Interface Language": "अपनी पसंदीदा ऐप और मेटाडेटा भाषा चुनें।",
            "App Information": "ऐप की जानकारी",
            "Version": "संस्करण",
            "Stream Sources": "स्ट्रीम स्रोत",
            "Stream Filter": "स्ट्रीम फ़िल्टर",
            "Flux Mode": "Flux मोड",
            "Enable Flux Mode": "Flux मोड सक्षम करें",
            "Maximum Resolution": "अधिकतम रिज़ॉल्यूशन",
            "Language Filter in Flux Mode": "Flux मोड में भाषा फ़िल्टर",
            "Video Player": "वीडियो प्लेयर",
            "Hardware Acceleration": "हार्डवेयर त्वरण",
            "Playback Behavior": "प्लेबैक व्यवहार",
            "Auto-play Next Episode": "अगला एपिसोड स्वतः चलाएं",
            "Audio": "ऑडियो",
            "Audio Passthrough (Atmos / DTS)": "ऑडियो पासथ्रू (Atmos / DTS)",
            "Languages": "भाषाएं",
            "Default Audio": "डिफ़ॉल्ट ऑडियो",
            "Default Subtitles": "डिफ़ॉल्ट उपशीर्षक",
            "Sign In": "साइन इन करें",
            "Sign Out": "साइन आउट करें",
            "Sync Now": "अब सिंक करें",
            "Cloud Sync": "क्लाउड सिंक"
        ],

        // 🇨🇳 Chinese (Simplified)
        .chinese: [
            "Search": "搜索",
            "Home": "首页",
            "Movies": "电影",
            "TV Shows": "剧集",
            "Trending": "热门推荐",
            "Watchlist": "待播清单",
            "Collections": "片单收藏",
            "History": "播放记录",
            "Downloads": "下载管理",
            "Browse": "探索",
            "Library": "我的片库",
            
            "Continue Watching": "继续观看",
            "Trending Today": "今日热门",
            "Trending This Week": "本周热门",
            "Popular Movies": "热门电影",
            "Popular TV Shows": "热门剧集",
            "Top Rated": "高分佳作",
            "Top Rated Movies": "高分电影",
            "Top Rated Shows": "高分剧集",
            "Popular on Streaming": "流媒体热门",
            "Animated Adventures": "精选动画",
            "Kids Shows": "少儿天地",
            "Family Movie Night": "家庭影院",
            "Quick Watches": "随心短剧",
            "Quick Watches (< 95m)": "短片速览 (< 95分钟)",
            "Airing Today": "今日开播",
            "On The Air": "热播中",
            "On TV": "正在热播",
            "Now Playing": "正在热映",
            "Upcoming": "即将上映",
            "Trending for Kids": "儿童热门",
            "Recently Watched": "最近观看",
            "Explore": "探索",
            "Browse by Genre": "按类型浏览",
            "Browse for Kids": "儿童精选",
            "Trending Movies Today": "今日热搜电影",
            "Trending Movies This Week": "本周热搜电影",
            "Trending Shows Today": "今日热搜剧集",
            "Trending Shows This Week": "本周热搜剧集",
            
            "Play": "播放",
            "Resume": "继续播放",
            "Start Over": "从头播放",
            "Watch Trailer": "观看预告片",
            "Add to Watchlist": "加入待播清单",
            "In Watchlist": "已在清单中",
            "Overview": "剧情简介",
            "Episodes": "剧集列表",
            "Cast & Crew": "演职人员",
            "Similar": "相似推荐",
            "Recommendations": "相关推荐",
            "Season": "季",
            "Episode": "集",
            "Streams": "播放源",
            "Next Episode": "下一集",
            "Subtitles": "字幕",
            "Audio Track": "音频轨道",
            "Speed": "倍速",
            "Close": "关闭",
            "Auto-Playing": "自动播放中",
            "Seeders": "做种数",
            "Quality": "画质",
            
            "New Collection": "新建片单",
            "Empty Watchlist": "待播清单为空",
            "In Progress": "观看中",
            "Completed": "已看完",
            "Clear History": "清空记录",
            
            "Settings": "设置",
            "General": "通用",
            "Streaming": "流媒体",
            "Addons": "插件管理",
            "Playback": "播放控制",
            "Advanced": "高级选项",
            "Account": "用户账户",
            "Watching Profiles": "观看档案",
            "Manage Profiles…": "管理档案…",
            "Catalog & Metadata": "片库与信息源",
            "App Language": "界面语言",
            "Select Interface Language": "选择您喜好的应用界面与影视元数据语言。",
            "App Information": "关于应用",
            "Version": "版本",
            "Stream Sources": "流媒体源",
            "Stream Filter": "源筛选",
            "Flux Mode": "极速 Flux 模式",
            "Enable Flux Mode": "开启 Flux 极速匹配",
            "Maximum Resolution": "最高画质上限",
            "Language Filter in Flux Mode": "Flux 模式语言优选",
            "Video Player": "视频解码器",
            "Hardware Acceleration": "硬件解码加速",
            "Playback Behavior": "播放行为",
            "Auto-play Next Episode": "自动播放下一集",
            "Audio": "音频输出",
            "Audio Passthrough (Atmos / DTS)": "音频直通透传 (Atmos / DTS)",
            "Languages": "音轨与字幕",
            "Default Audio": "默认音频",
            "Default Subtitles": "默认字幕",
            "Sign In": "登录",
            "Sign Out": "登出",
            "Sync Now": "立即同步",
            "Cloud Sync": "云端同步"
        ]
    ]
}

// MARK: - Convenient Localized String Extension

extension String {
    /// Returns the localized string for the current app language.
    @MainActor
    public var localized: String {
        L10n.tr(self)
    }
}
