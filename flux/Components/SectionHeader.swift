import SwiftUI

struct SectionHeader<Destination: View>: View {
    let title: String
    let destination: Destination
    
    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.title2) // Matches Apple TV section header size
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold)) // Smaller, bold chevron
                    .foregroundColor(.gray.opacity(0.7))
                    .padding(.top, 2) // Slight optical alignment
            }
            .contentShape(Rectangle()) // Make the whole area clickable
        }
        .buttonStyle(.plain) // Removes default button styling
    }
}

struct ListSectionHeader<Value: Hashable>: View {
    let title: String
    let value: Value
    
    var body: some View {
        NavigationLink(value: value) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.gray.opacity(0.7))
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TrendingToggleSectionHeader<Value: Hashable>: View {
    var title: String = "Trending"
    @Binding var window: String // "day" or "week"
    let value: Value

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink(value: value) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)

            // Liquid Glass Sliding & Draggable Toggle (Before the forward arrow)
            LiquidGlassSegmentedToggle(selected: $window)

            NavigationLink(value: value) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.gray.opacity(0.7))
                    .padding(.leading, 2)
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }
}

// MARK: - Motion Constants

enum GlassMotion {
    static let popOut = Animation.spring(response: 0.28, dampingFraction: 0.62, blendDuration: 0.08)
    static let drag = Animation.interactiveSpring(response: 0.12, dampingFraction: 0.86, blendDuration: 0.1)
    static let settle = Animation.spring(response: 0.46, dampingFraction: 0.76, blendDuration: 0.18)
    static let squish = Animation.spring(response: 0.32, dampingFraction: 0.5, blendDuration: 0.12)
    static let reduced = Animation.easeInOut(duration: 0.18)
}

struct LiquidGlassSegmentedToggle: View {
    @Binding var selected: String // "day" or "week"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var squishX: CGFloat = 1
    @State private var lastDragX: CGFloat?
    @State private var lastDragTime = Date()
    @State private var velocityX: CGFloat = 0

    private let segmentWidth: CGFloat = 72
    private let height: CGFloat = 28
    private let padding: CGFloat = 2

    private var activeIndex: Int {
        selected == "day" ? 0 : 1
    }

    private var thumbWidth: CGFloat {
        segmentWidth - (padding * 2)
    }

    private var thumbHeight: CGFloat {
        height - (padding * 2)
    }

    private var currentThumbOffset: CGFloat {
        let base = CGFloat(activeIndex) * segmentWidth + padding
        if isDragging {
            let proposed = base + dragOffset
            let minX = padding
            let maxX = segmentWidth + padding
            if proposed < minX {
                return minX - rubberBand(minX - proposed, dimension: segmentWidth * 2)
            } else if proposed > maxX {
                return maxX + rubberBand(proposed - maxX, dimension: segmentWidth * 2)
            }
            return proposed
        }
        return base
    }

    private var squishCompensation: CGFloat {
        max(0.85, min(1.15, 2 - squishX))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // 1. Track Socket with permanently positioned labels
            HStack(spacing: 0) {
                Text("Today")
                    .font(.system(size: 11, weight: selected == "day" ? .bold : .semibold))
                    .foregroundStyle(selected == "day" ? Color.white : Color.white.opacity(0.50))
                    .frame(width: segmentWidth, height: height)

                Text("This Week")
                    .font(.system(size: 11, weight: selected == "week" ? .bold : .semibold))
                    .foregroundStyle(selected == "week" ? Color.white : Color.white.opacity(0.50))
                    .frame(width: segmentWidth, height: height)
            }
            .frame(width: segmentWidth * 2, height: height)
            .glassEffect(.regular, in: .capsule)

            // 2. Empty, Zero-Distortion Crystal-Clear Glass Pill (Glides directly OVER socket labels)
            Capsule()
                .fill(Color.white.opacity(isDragging ? 0.12 : 0.08))
                .overlay(
                    // Crisp Specular Glass Rim Glint
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isDragging ? 0.75 : 0.38),
                                    Color.white.opacity(isDragging ? 0.22 : 0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isDragging ? 1.0 : 0.7
                        )
                )
                .frame(width: thumbWidth, height: thumbHeight)
                // Height pops out significantly when held, extending above and below the track
                .scaleEffect(
                    x: reduceMotion ? 1 : (isDragging ? 1.06 * squishX : 1.0),
                    y: reduceMotion ? 1 : (isDragging ? 1.32 : 1.0),
                    anchor: .center
                )
                .shadow(
                    color: Color.black.opacity(isDragging ? 0.45 : 0.12),
                    radius: isDragging ? 16 : 3,
                    x: 0,
                    y: isDragging ? 8 : 1
                )
                .offset(x: currentThumbOffset)
                .animation(isDragging ? GlassMotion.drag : (reduceMotion ? GlassMotion.reduced : GlassMotion.settle), value: currentThumbOffset)
                .animation(reduceMotion ? GlassMotion.reduced : GlassMotion.popOut, value: isDragging)
        }
        .frame(width: segmentWidth * 2, height: height)
        .contentShape(Capsule())
        // Unified gesture handling for instantaneous drag tracking + tap support
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                    }
                    dragOffset = value.translation.width
                    updateVelocity(currentX: value.location.x)

                    if !reduceMotion {
                        withAnimation(GlassMotion.squish) {
                            squishX = squishFactor(for: velocityX)
                        }
                    }
                }
                .onEnded { value in
                    let translation = value.translation.width
                    let projectedX = (selected == "day" ? padding : segmentWidth + padding) + translation + velocityX * 0.12
                    let tapLocation = value.location.x

                    lastDragX = nil
                    velocityX = 0

                    withAnimation(reduceMotion ? GlassMotion.reduced : GlassMotion.settle) {
                        squishX = 1
                        if abs(translation) < 6 {
                            // Tap resolution based on hit location
                            if tapLocation < segmentWidth {
                                selected = "day"
                            } else {
                                selected = "week"
                            }
                        } else {
                            // Drag / flick resolution based on projection
                            if projectedX > segmentWidth * 0.7 {
                                selected = "week"
                            } else {
                                selected = "day"
                            }
                        }
                        dragOffset = 0
                        isDragging = false
                    }
                }
        )
    }

    private func updateVelocity(currentX: CGFloat) {
        let now = Date()
        if let last = lastDragX {
            let dt = max(now.timeIntervalSince(lastDragTime), 1.0 / 120.0)
            velocityX = (currentX - last) / CGFloat(dt)
        }
        lastDragX = currentX
        lastDragTime = now
    }

    private func squishFactor(for velocity: CGFloat) -> CGFloat {
        let normalized = max(-1, min(1, velocity / 900))
        return 1 + normalized * 0.16
    }

    private func rubberBand(_ overflow: CGFloat, dimension: CGFloat, coefficient: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0 else { return 0 }
        return (overflow * coefficient * dimension) / (dimension + coefficient * overflow)
    }
}

#Preview {
    ZStack {
        Color.black
        SectionHeader(title: "Trending Movies", destination: Text("Destination"))
    }
}
