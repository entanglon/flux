import SwiftUI

/// Universal glass effect adapter: Uses native Apple Liquid Glass (.glassEffect) on macOS 26+
/// and gracefully falls back to ultraThinMaterial vibrancy on macOS 14 & 15.
public struct FluxGlass: Equatable, Sendable {
    public var isClear: Bool
    public var isInteractive: Bool

    public static let regular = FluxGlass(isClear: false, isInteractive: false)
    public static let clear = FluxGlass(isClear: true, isInteractive: false)

    public func interactive() -> FluxGlass {
        FluxGlass(isClear: self.isClear, isInteractive: true)
    }
}

public typealias Glass = FluxGlass

public extension View {
    @ViewBuilder
    func glassEffect(_ glass: FluxGlass = .regular, in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            let nativeGlass: SwiftUI.Glass = {
                if glass.isClear {
                    return glass.isInteractive ? .clear.interactive() : .clear
                } else {
                    return glass.isInteractive ? .regular.interactive() : .regular
                }
            }()
            self.glassEffect(nativeGlass, in: shape)
        } else {
            if glass.isClear {
                self.background(
                    shape.fill(Color.white.opacity(0.06))
                        .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                )
            } else {
                self.background(
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                )
            }
        }
    }
}
