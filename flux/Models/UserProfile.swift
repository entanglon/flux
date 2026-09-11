import Foundation
import SwiftUI

struct UserProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var avatarID: String
    var createdAt: Date
    var isKids: Bool
    var isStock: Bool

    init(id: UUID, name: String, avatarID: String, createdAt: Date, isKids: Bool = false, isStock: Bool = false) {
        self.id = id
        self.name = name
        self.avatarID = avatarID
        self.createdAt = createdAt
        self.isKids = isKids
        self.isStock = isStock
    }

    enum CodingKeys: String, CodingKey {
        case id, name, avatarID, createdAt, isKids, isStock
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        avatarID = try container.decode(String.self, forKey: .avatarID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isKids = try container.decodeIfPresent(Bool.self, forKey: .isKids) ?? false
        isStock = try container.decodeIfPresent(Bool.self, forKey: .isStock) ?? false
    }
}

/// Netflix-style profile avatars: solid color tiles with minimalist drawn
/// faces — rendered programmatically (crisp at any size, no image assets).
struct AvatarStyle: Identifiable, Hashable {
    enum FaceKind: String, Codable {
        case smile, laugh, grinning, sunglasses, heartEyes, wink, surprised, sleepy, tongue, cool
    }

    let id: String
    let background: Color
    let face: FaceKind

    static let all: [AvatarStyle] = [
        AvatarStyle(id: "face-red",     background: Color(red: 0.90, green: 0.15, blue: 0.15), face: .smile),
        AvatarStyle(id: "face-blue",    background: Color(red: 0.15, green: 0.45, blue: 0.90), face: .sunglasses),
        AvatarStyle(id: "face-green",   background: Color(red: 0.15, green: 0.65, blue: 0.30), face: .laugh),
        AvatarStyle(id: "face-yellow",  background: Color(red: 0.95, green: 0.72, blue: 0.08), face: .wink),
        AvatarStyle(id: "face-purple",  background: Color(red: 0.55, green: 0.25, blue: 0.80), face: .heartEyes),
        AvatarStyle(id: "face-teal",    background: Color(red: 0.08, green: 0.58, blue: 0.58), face: .surprised),
        AvatarStyle(id: "face-orange",  background: Color(red: 0.95, green: 0.48, blue: 0.08), face: .grinning),
        AvatarStyle(id: "face-pink",    background: Color(red: 0.90, green: 0.28, blue: 0.52), face: .tongue),
        AvatarStyle(id: "face-navy",    background: Color(red: 0.12, green: 0.20, blue: 0.45), face: .sleepy),
        AvatarStyle(id: "face-crimson", background: Color(red: 0.68, green: 0.10, blue: 0.20), face: .cool),
        AvatarStyle(id: "face-lime",    background: Color(red: 0.50, green: 0.72, blue: 0.12), face: .smile),
        AvatarStyle(id: "face-magenta", background: Color(red: 0.72, green: 0.18, blue: 0.58), face: .laugh)
    ]

    static func style(for id: String) -> AvatarStyle {
        all.first { $0.id == id } ?? all[0]
    }
}

/// Avatar item model supporting both illustrated character assets and programmatic faces.
public struct AvatarItem: Identifiable, Hashable {
    public enum Category: String, CaseIterable {
        case characters = "Cats"
        case pets = "Pets"
        case classic = "Faces"
    }

    public let id: String
    public let name: String
    public let category: Category
    public let isImage: Bool

    public static let characters: [AvatarItem] = [
        AvatarItem(id: "avatar-cat-1", name: "Happy Pink", category: .characters, isImage: true),
        AvatarItem(id: "avatar-cat-2", name: "Smirk Green", category: .characters, isImage: true),
        AvatarItem(id: "avatar-cat-3", name: "Laugh Pink", category: .characters, isImage: true),
        AvatarItem(id: "avatar-cat-4", name: "Excited Yellow", category: .characters, isImage: true),
        AvatarItem(id: "avatar-cat-5", name: "Sneak Yellow", category: .characters, isImage: true),
        AvatarItem(id: "avatar-cat-6", name: "Sly Blue", category: .characters, isImage: true),
        AvatarItem(id: "avatar-cat-7", name: "Hero Pink", category: .characters, isImage: true),
        AvatarItem(id: "avatar-cat-8", name: "Corner Pink", category: .characters, isImage: true)
    ]

    public static let pets: [AvatarItem] = (1...12).map {
        AvatarItem(id: "avatar-pet-\($0)", name: "Pet \($0)", category: .pets, isImage: true)
    }

    public static let classics: [AvatarItem] = AvatarStyle.all.map {
        AvatarItem(id: $0.id, name: $0.id.replacingOccurrences(of: "face-", with: "").capitalized, category: .classic, isImage: false)
    }

    public static let all: [AvatarItem] = characters + pets + classics
}

/// Draws the minimalist face on a color tile.
struct AvatarFaceView: View {
    let style: AvatarStyle

    var body: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [style.background, style.background.opacity(0.82)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            face
        }
    }

    @ViewBuilder
    private var face: some View {
        let s = style.face
        if s == .sunglasses || s == .cool {
            SunglassesFace(cool: s == .cool)
        } else if s == .sleepy {
            SleepyFace()
        } else {
            EyesAndMouthFace(kind: s)
        }
    }
}

// MARK: - Face Components

private struct EyesAndMouthFace: View {
    let kind: AvatarStyle.FaceKind

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let eyeY = w * 0.36
            let eyeOffset = w * 0.17
            let eyeR = w * 0.075

            ZStack {
                if kind == .heartEyes {
                    HeartShape()
                        .fill(Color.white)
                        .frame(width: w * 0.17, height: w * 0.15)
                        .position(x: w / 2 - eyeOffset, y: eyeY)
                    HeartShape()
                        .fill(Color.white)
                        .frame(width: w * 0.17, height: w * 0.15)
                        .position(x: w / 2 + eyeOffset, y: eyeY)
                } else if kind == .wink {
                    // Left eye open, right eye CLOSED — a lone tilted line reads
                    // as a wink; a capsule over a full circle just reads squashed.
                    Circle().fill(Color.white).frame(width: eyeR * 2)
                        .position(x: w / 2 - eyeOffset, y: eyeY)
                    Capsule().fill(Color.white)
                        .frame(width: eyeR * 2.3, height: w * 0.055)
                        .rotationEffect(.degrees(-10))
                        .position(x: w / 2 + eyeOffset, y: eyeY)
                } else {
                    // Eyes
                    Circle().fill(Color.white).frame(width: eyeR * 2)
                        .position(x: w / 2 - eyeOffset, y: eyeY)
                    Circle().fill(Color.white).frame(width: eyeR * 2)
                        .position(x: w / 2 + eyeOffset, y: eyeY)
                }

                // Mouth
                switch kind {
                case .laugh:
                    // Open laughing mouth
                    Ellipse().fill(Color.white)
                        .frame(width: w * 0.30, height: w * 0.20)
                        .position(x: w / 2, y: w * 0.66)
                    Ellipse().fill(Color(red: 0.75, green: 0.25, blue: 0.25))
                        .frame(width: w * 0.20, height: w * 0.10)
                        .position(x: w / 2, y: w * 0.72)
                case .grinning:
                    // Wide filled grin
                    Circle()
                        .trim(from: 0, to: 0.5)
                        .rotation(.degrees(180))
                        .fill(Color.white)
                        .frame(width: w * 0.42, height: w * 0.42)
                        .position(x: w / 2, y: w * 0.50)
                case .surprised:
                    Circle().fill(Color.white)
                        .frame(width: w * 0.14, height: w * 0.14)
                        .position(x: w / 2, y: w * 0.66)
                case .tongue:
                    SmileArc()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: w * 0.055, lineCap: .round))
                        .frame(width: w * 0.44, height: w * 0.44)
                        .position(x: w / 2, y: w * 0.47)
                    Ellipse().fill(Color.white)
                        .frame(width: w * 0.14, height: w * 0.16)
                        .position(x: w * 0.56, y: w * 0.70)
                    Ellipse().fill(Color(red: 0.95, green: 0.45, blue: 0.55))
                        .frame(width: w * 0.10, height: w * 0.11)
                        .position(x: w * 0.56, y: w * 0.73)
                case .heartEyes:
                    SmileArc()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: w * 0.055, lineCap: .round))
                        .frame(width: w * 0.44, height: w * 0.44)
                        .position(x: w / 2, y: w * 0.47)
                default:
                    SmileArc()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: w * 0.055, lineCap: .round))
                        .frame(width: w * 0.44, height: w * 0.44)
                        .position(x: w / 2, y: w * 0.47)
                }
            }
        }
    }
}

private struct SunglassesFace: View {
    var cool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                // Left lens
                LensShape()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: w * 0.24, height: w * 0.16)
                    .position(x: w * 0.33, y: w * 0.36)
                // Right lens
                LensShape()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: w * 0.24, height: w * 0.16)
                    .position(x: w * 0.67, y: w * 0.36)
                // Bridge
                Rectangle()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: w * 0.12, height: w * 0.045)
                    .position(x: w / 2, y: w * 0.35)

                if cool {
                    // Flat unimpressed mouth
                    Capsule().fill(Color.white)
                        .frame(width: w * 0.26, height: w * 0.045)
                        .position(x: w / 2, y: w * 0.68)
                } else {
                    SmileArc()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: w * 0.055, lineCap: .round))
                        .frame(width: w * 0.44, height: w * 0.44)
                        .position(x: w / 2, y: w * 0.47)
                }
            }
        }
    }
}

private struct SleepyFace: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                ClosedEye()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: w * 0.05, lineCap: .round))
                    .frame(width: w * 0.16, height: w * 0.10)
                    .position(x: w / 2 - w * 0.17, y: w * 0.38)
                ClosedEye()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: w * 0.05, lineCap: .round))
                    .frame(width: w * 0.16, height: w * 0.10)
                    .position(x: w / 2 + w * 0.17, y: w * 0.38)

                // Small content smile
                SmileArc()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: w * 0.05, lineCap: .round))
                    .frame(width: w * 0.40, height: w * 0.40)
                    .position(x: w / 2, y: w * 0.47)
            }
        }
    }
}

// MARK: - Shapes

private struct SmileArc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.08),
                 radius: rect.width * 0.30,
                 startAngle: .degrees(25),
                 endAngle: .degrees(155),
                 clockwise: false)
        return p
    }
}

private struct ClosedEye: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.minY),
                 radius: rect.width / 2,
                 startAngle: .degrees(20),
                 endAngle: .degrees(160),
                 clockwise: false)
        return p
    }
}

private struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.size.width
        let h = rect.size.height
        p.move(to: CGPoint(x: w / 2, y: h))
        p.addCurve(to: CGPoint(x: 0, y: h * 0.3),
                   control1: CGPoint(x: w * 0.1, y: h * 0.75),
                   control2: CGPoint(x: 0, y: h * 0.5))
        p.addArc(center: CGPoint(x: w * 0.25, y: h * 0.28), radius: w * 0.25,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addArc(center: CGPoint(x: w * 0.75, y: h * 0.28), radius: w * 0.25,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addCurve(to: CGPoint(x: w / 2, y: h),
                   control1: CGPoint(x: w, y: h * 0.5),
                   control2: CGPoint(x: w * 0.9, y: h * 0.75))
        p.closeSubpath()
        return p
    }
}

private struct LensShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.35, style: .continuous)
    }
}
