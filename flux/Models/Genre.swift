import Foundation

struct Genre: Identifiable, Hashable {
    let id: Int
    let name: String
    let icon: String?
    let imageURL: String? // Unsplash URL or local image
    
    static let allGenres: [Genre] = [
        Genre(id: 28, name: "Action", icon: "bolt.fill", imageURL: "https://unsplash.com/photos/r1SwcagHVG0/download?force=true"),
        Genre(id: 12, name: "Adventure", icon: "mountain.2.fill", imageURL: "https://unsplash.com/photos/HVWVERp33tQ/download?force=true"),
        Genre(id: 878, name: "Sci-Fi", icon: "sparkles", imageURL: "https://unsplash.com/photos/RgkpHQtcrAE/download?force=true"),
        Genre(id: 35, name: "Comedy", icon: "face.smiling.fill", imageURL: "https://unsplash.com/photos/ohbfKsIEbJQ/download?force=true"),
        Genre(id: 18, name: "Drama", icon: "theatermasks.fill", imageURL: "https://unsplash.com/photos/65UK3Fa_yIg/download?force=true"),
        Genre(id: 53, name: "Thriller", icon: "waveform.path.ecg", imageURL: "https://unsplash.com/photos/wmTmcpeHzrI/download?force=true"),
        Genre(id: 27, name: "Horror", icon: "ghost.fill", imageURL: "https://unsplash.com/photos/uFUQ55RuMrs/download?force=true"),
        Genre(id: 10749, name: "Romance", icon: "heart.fill", imageURL: "https://unsplash.com/photos/w5hhoYM_JsU/download?force=true"),
        Genre(id: 14, name: "Fantasy", icon: "wand.and.stars", imageURL: "https://unsplash.com/photos/facU72FcKBI/download?force=true"),
        Genre(id: 16, name: "Animation", icon: "paintpalette.fill", imageURL: "https://unsplash.com/photos/JINPheIkUek/download?force=true"),
        Genre(id: 80, name: "Crime", icon: "shield.fill", imageURL: "https://unsplash.com/photos/W1J8mMlkmXY/download?force=true"),
        Genre(id: 99, name: "Documentary", icon: "mic.fill", imageURL: "https://unsplash.com/photos/9EW7VkfJkSg/download?force=true")
    ]
}
