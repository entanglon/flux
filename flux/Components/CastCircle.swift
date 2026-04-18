import SwiftUI

struct CastCircle: View {
    let name: String
    let imageURL: URL?
    let size: CGFloat
    
    var initials: String {
        let formatter = PersonNameComponentsFormatter()
        if let components = formatter.personNameComponents(from: name) {
            formatter.style = .abbreviated
            return formatter.string(from: components)
        }
        return String(name.prefix(1)).uppercased()
    }
    
    var body: some View {
        ZStack {
            if let url = imageURL {
                AsyncImage(url: url) { image in
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    initialsPlaceholder
                }
            } else {
                initialsPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .glassEffect(.regular, in: .circle)
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
    }
    
    private var initialsPlaceholder: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(hue: Double(abs(name.hashValue) % 100) / 100.0, saturation: 0.6, brightness: 0.8),
                    Color(hue: Double(abs(name.hashValue) % 100) / 100.0, saturation: 0.4, brightness: 0.4)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Text(initials)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundColor(.white)
                .shadow(radius: 2)
        }
    }
}
