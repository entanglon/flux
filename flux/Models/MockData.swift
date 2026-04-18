import Foundation

struct MockData {
    static let sampleCast = [
        CastMember(name: "Actor One", role: "Protagonist", imageURL: nil),
        CastMember(name: "Actor Two", role: "Antagonist", imageURL: nil),
        CastMember(name: "Actor Three", role: "Supporting", imageURL: nil),
        CastMember(name: "Director Name", role: "Director", imageURL: nil)
    ]

    static let sampleMedia: [MediaItem] = [
        MediaItem(
            id: UUID().uuidString,
            title: "Urban Rhythm",
            description: "The beat of the city never stops. A documentary exploring the underground music scene.",
            imageURL: URL(string: "https://images.unsplash.com/photo-1514525253440-b393452e8d26?auto=format&fit=crop&w=800&q=80"),
            streamURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"),
            category: "Documentary",
            progress: 0.4,
            trailerURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"),
            cast: sampleCast
        ),
        MediaItem(
            id: UUID().uuidString,
            title: "Cosmic Voyage",
            description: "A journey through the stars to find a new home for humanity.",
            imageURL: URL(string: "https://images.unsplash.com/photo-1462331940025-496dfbfc7564?auto=format&fit=crop&w=800&q=80"),
            streamURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4"),
            category: "Sci-Fi",
            progress: nil,
            trailerURL: nil,
            cast: sampleCast
        ),
        MediaItem(
            id: UUID().uuidString,
            title: "Ocean Depths",
            description: "Discover the mysteries lurking beneath the surface of our oceans.",
            imageURL: URL(string: "https://images.unsplash.com/photo-1582967788606-a171f1080ca8?auto=format&fit=crop&w=800&q=80"),
            streamURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4"),
            category: "Documentary",
            progress: 0.8,
            trailerURL: nil,
            cast: sampleCast
        ),
        MediaItem(
            id: UUID().uuidString,
            title: "Mountain Peak",
            description: "Scaling the highest peaks on Earth. A story of endurance and survival.",
            imageURL: URL(string: "https://images.unsplash.com/photo-1464822759023-fed622ff2c3b?auto=format&fit=crop&w=800&q=80"),
            streamURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4"),
            category: "Adventure",
            progress: nil,
            trailerURL: nil,
            cast: sampleCast
        ),
        MediaItem(
            id: UUID().uuidString,
            title: "Cyber City",
            description: "In a neon-soaked future, one detective must solve the ultimate crime.",
            imageURL: URL(string: "https://images.unsplash.com/photo-1535498730771-e735b998cd64?auto=format&fit=crop&w=800&q=80"),
            streamURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4"),
            category: "Sci-Fi",
            progress: 0.1,
            trailerURL: nil,
            cast: sampleCast
        )
    ]
    
    static let categories = ["Trending", "New Releases", "Sci-Fi", "Documentary"]
}
