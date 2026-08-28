import Foundation

struct Genre: Identifiable, Hashable {
    let id: Int
    let name: String
    let icon: String?
    let imageURL: String? // Unsplash URL or local image
    
    static let allGenres: [Genre] = [
        Genre(id: 28, name: "Action", icon: "bolt.fill", imageURL: nil),
        Genre(id: 12, name: "Adventure", icon: "mountain.2.fill", imageURL: nil),
        Genre(id: 16, name: "Animation", icon: "paintpalette.fill", imageURL: nil),
        Genre(id: 10001, name: "Anime", icon: "sparkles.tv.fill", imageURL: nil),
        Genre(id: 10002, name: "Bollywood", icon: "music.note.tv.fill", imageURL: nil),
        Genre(id: 10003, name: "Classics", icon: "film.stack.fill", imageURL: nil),
        Genre(id: 35, name: "Comedy", icon: "face.smiling.fill", imageURL: nil),
        Genre(id: 80, name: "Crime", icon: "shield.fill", imageURL: nil),
        Genre(id: 99, name: "Documentary", icon: "mic.fill", imageURL: nil),
        Genre(id: 18, name: "Drama", icon: "theatermasks.fill", imageURL: nil),
        Genre(id: 14, name: "Fantasy", icon: "wand.and.stars", imageURL: nil),
        Genre(id: 27, name: "Horror", icon: "skull.fill", imageURL: nil),
        Genre(id: 10004, name: "K-Drama", icon: "heart.text.square.fill", imageURL: nil),
        Genre(id: 10749, name: "Romance", icon: "heart.fill", imageURL: nil),
        Genre(id: 878, name: "Sci-Fi", icon: "sparkles", imageURL: nil),
        Genre(id: 10005, name: "Short Films", icon: "timer", imageURL: nil),
        Genre(id: 53, name: "Thriller", icon: "waveform.path.ecg", imageURL: nil),
        Genre(id: 37, name: "Western", icon: "hat.widebrim.fill", imageURL: nil)
    ]
}
