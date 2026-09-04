#if FLUX_LEGACY
import SwiftUI

/// Legacy fallback for macOS 15 and earlier versions where native Apple Liquid Glass (.glassEffect) is unavailable.
public struct FluxLegacyGlass: Equatable, Sendable {
    public var isClear: Bool
    public var isInteractive: Bool

    public static let regular = FluxLegacyGlass(isClear: false, isInteractive: false)
    public static let clear = FluxLegacyGlass(isClear: true, isInteractive: false)

    public func interactive() -> FluxLegacyGlass {
        FluxLegacyGlass(isClear: self.isClear, isInteractive: true)
    }
}

public typealias Glass = FluxLegacyGlass

public extension View {
    @ViewBuilder
    func glassEffect(_ glass: FluxLegacyGlass = .regular, in shape: some Shape) -> some View {
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
#endif
