import SwiftUI

// MARK: - WWDC 2025 Liquid Glass Polyfill
// "Bringing the future of iOS 26 Liquid Glass to macOS today"

// MARK: - Glass Style
public struct GlassStyle: Sendable {
    public enum Variant {
        case regular
        case clear
        case identity
    }
    
    let variant: Variant
    var tintColor: Color?
    var isInteractive: Bool = false
    
    public init(_ variant: Variant) {
        self.variant = variant
    }
    
    public func tint(_ color: Color) -> GlassStyle {
        var copy = self
        copy.tintColor = color
        return copy
    }
    
    public func interactive(_ isEnabled: Bool = true) -> GlassStyle {
        var copy = self
        copy.isInteractive = isEnabled
        return copy
    }
    
    public static let regular = GlassStyle(.regular)
    public static let clear = GlassStyle(.clear)
    public static let identity = GlassStyle(.identity)
}

// MARK: - Glass Shape
public enum GlassShape {
    case capsule
    case circle
    case rect(cornerRadius: CGFloat)
    case roundedRectangle(cornerRadius: CGFloat)
    
    var shape: AnyShape {
        switch self {
        case .capsule: return AnyShape(Capsule())
        case .circle: return AnyShape(Circle())
        case .rect(let radius): return AnyShape(RoundedRectangle(cornerRadius: radius))
        case .roundedRectangle(let radius): return AnyShape(RoundedRectangle(cornerRadius: radius))
        }
    }
}

// MARK: - Glass View
public struct GlassView: View {
    let style: GlassStyle

    public init(style: GlassStyle) {
        self.style = style
    }

    public var body: some View {
        switch style.variant {
        case .regular, .clear:
            ZStack {
                Rectangle()
                    .fill(.regularMaterial)
                    .opacity(style.variant == .clear ? 0.28 : 0.80)

                if let tint = style.tintColor {
                    Rectangle()
                        .fill(tint.opacity(0.10))
                        .blendMode(.overlay)
                }

                Rectangle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.0), .white.opacity(0.08)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 80
                        )
                    )
                    .blendMode(.screen)
            }
        case .identity:
            Color.clear
        }
    }
}

// MARK: - Modifiers hierarchy
struct GlassEffectModifier: ViewModifier {
    var style: GlassStyle
    var shape: AnyShape
    var namespace: Namespace.ID?
    var id: AnyHashable?

    @State private var isHovering = false
    @State private var pointerLocation: CGPoint = .zero

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    GlassView(style: style)
                        .clipShape(shape)

                    shape
                        .stroke(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.6), location: 0.0),
                                    .init(color: .clear, location: 0.2),
                                    .init(color: .clear, location: 0.8),
                                    .init(color: .white.opacity(0.35), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1.5
                        )
                        .blendMode(.overlay)
                        .blur(radius: 0.5)

                    GeometryReader { proxy in
                        let size = proxy.size
                        let normalized = CGPoint(
                            x: max(0, min(pointerLocation.x / max(size.width, 1), 1)),
                            y: max(0, min(pointerLocation.y / max(size.height, 1), 1))
                        )

                        RadialGradient(
                            gradient: Gradient(colors: [
                                .white.opacity(isHovering ? 0.10 : 0.0),
                                .white.opacity(0.0)
                            ]),
                            center: UnitPoint(x: normalized.x, y: normalized.y),
                            startRadius: 0,
                            endRadius: max(size.width, size.height) * 0.4
                        )
                        .blendMode(.plusLighter)
                    }
                    .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(style.variant == .clear ? 0.08 : 0.22), radius: 10, x: 0, y: 6)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovering = hovering
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        pointerLocation = point
                    case .ended:
                        break
                    }
                }
            )
            .overlay(
                shape
                    .stroke(.white.opacity(0.12), lineWidth: 0.5)
                    .blendMode(.plusLighter)
            )
            .if(namespace != nil && id != nil) { view in
                view.matchedGeometryEffect(id: id!, in: namespace!)
            }
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.70), value: isHovering)
    }
}

struct InteractiveModifier: ViewModifier {
    var isEnabled: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isEnabled && isHovering ? 1.05 : 1.0)
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.65), value: isHovering)
            .onHover { hovering in
                if isEnabled {
                    isHovering = hovering
                }
            }
    }
}

// MARK: - Liquid Glass Implementation
struct LiquidAnchorKey: PreferenceKey {
    static var defaultValue: [String: [Anchor<CGRect>]] = [:]
    
    static func reduce(value: inout [String: [Anchor<CGRect>]], nextValue: () -> [String: [Anchor<CGRect>]]) {
        let next = nextValue()
        for (key, anchors) in next {
            value[key, default: []].append(contentsOf: anchors)
        }
    }
}

struct LiquidMotionEffectModifier: ViewModifier {
    var id: AnyHashable
    var namespace: Namespace.ID
    
    func body(content: Content) -> some View {
        content
            .anchorPreference(key: LiquidAnchorKey.self, value: .bounds) { anchor in
                [String(describing: id): [anchor]]
            }
    }
}

// MARK: - Extensions
extension View {
    
    // 1. The Main API
    public func glassEffect(_ style: GlassStyle = .regular, in shape: GlassShape = .capsule) -> some View {
        self.glassEffect(style, in: shape.shape)
    }
    
    // 2. Shape-only convenience
    public func glassEffect(in shape: GlassShape) -> some View {
        self.glassEffect(.regular, in: shape.shape)
    }

    // Internal implementation
    func glassEffect(_ style: GlassStyle, in shape: some Shape, namespace: Namespace.ID? = nil, id: AnyHashable? = nil) -> some View {
        self.modifier(GlassEffectModifier(style: style, shape: AnyShape(shape), namespace: namespace, id: id))
    }
    
    // 3. Morphing API (Legacy/Snippet Support)
    // Supports: .glassEffectID("sparkles", in: glassNamespace)
    public func glassEffectID(_ id: AnyHashable, in namespace: Namespace.ID) -> some View {
        self.matchedGeometryEffect(id: id, in: namespace)
    }
    
    public func glassEffect(_ shape: some Shape, in namespace: Namespace.ID, id: AnyHashable) -> some View {
        self.modifier(GlassEffectModifier(style: .regular, shape: AnyShape(shape), namespace: namespace, id: id))
    }
    
    // 4. Liquid Union (Snippet Support)
    public func glassEffectUnion(id: AnyHashable, namespace: Namespace.ID) -> some View {
        self.modifier(LiquidMotionEffectModifier(id: id, namespace: namespace))
    }
    
    public func interactive(_ isEnabled: Bool = true) -> some View {
        self.modifier(InteractiveModifier(isEnabled: isEnabled))
    }
}

// MARK: - GlassEffectContainer
public struct GlassEffectContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content
    
    public init(spacing: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }
    
    public var body: some View {
        ZStack {
            // Liquid Layer (Background Metaballs)
            // This renders a blurred, thresholded layer of the labeled views
            Color.clear
                .overlayPreferenceValue(LiquidAnchorKey.self) { preferences in
                    GeometryReader { proxy in
                        Canvas { context, size in
                            for (_, anchors) in preferences {
                                for anchor in anchors {
                                    let rect = proxy[anchor]
                                    // Blobs are slightly larger to connect
                                    let blobRect = rect.insetBy(dx: -8, dy: -8)
                                    context.fill(Path(roundedRect: blobRect, cornerRadius: blobRect.height/2), with: .color(.white))
                                }
                            }
                        }
                        .blur(radius: 12)
                        // In a real liquid engine we would use a threshold shader.
                        // For vanilla SwiftUI, high contrast simulates thresholding on the blur.
                        .contrast(25)
                        .opacity(0.4) // Subtle liquid connection
                        .blendMode(.plusLighter)
                    }
                }
                .allowsHitTesting(false)
            
            content
        }
    }
}

// MARK: - Helpers
public struct AnyShape: Shape, @unchecked Sendable {
    private let _path: (CGRect) -> Path
    
    public init<S: Shape>(_ shape: S) {
        _path = { rect in
            let path = shape.path(in: rect)
            return path
        }
    }
    
    public func path(in rect: CGRect) -> Path {
        _path(rect)
    }
}

// MARK: - Button Style
public struct GlassButtonStyle: ButtonStyle {
    var shape: GlassShape
    var style: GlassStyle
    var isProminent: Bool
    
    public init(shape: GlassShape = .capsule, style: GlassStyle = .regular, isProminent: Bool = false) {
        self.shape = shape
        self.style = style
        self.isProminent = isProminent
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .glassEffect(style.interactive(true), in: shape)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .if(isProminent) { view in
                view.overlay(
                    shape.shape
                        .stroke(Color.white.opacity(0.6), lineWidth: 1.5)
                        .blendMode(.overlay)
                )
                .shadow(color: .white.opacity(0.25), radius: 10)
            }
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    public static var glass: GlassButtonStyle { GlassButtonStyle() }
    
    public static func glass(shape: GlassShape = .capsule) -> GlassButtonStyle {
        GlassButtonStyle(shape: shape)
    }
    
    public static var glassProminent: GlassButtonStyle {
        GlassButtonStyle(isProminent: true)
    }
}

// Compatibility Type Alias
public typealias Glass = GlassStyle

// MARK: - RefractiveGlassCircle
public struct RefractiveGlassCircle: View {
    public var diameter: CGFloat
    
    public init(diameter: CGFloat) {
        self.diameter = diameter
    }
    
    public var body: some View {
        Circle()
            .glassEffect(.regular, in: .circle)
            .frame(width: diameter, height: diameter)
    }
}
