import SwiftUI

struct CarouselView<Item, Content>: View where Item: Identifiable, Content: View {
    let items: [Item]
    let content: (Item, Int) -> Content
    let itemWidth: CGFloat
    let spacing: CGFloat
    
    @State private var firstVisibleIndex: Int = 0
    @State private var isHovering: Bool = false
    
    let scrollStep = 3
    
    // Init with index
    init(items: [Item], spacing: CGFloat = 24, itemWidth: CGFloat = 180, @ViewBuilder content: @escaping (Item, Int) -> Content) {
        self.items = items
        self.spacing = spacing
        self.itemWidth = itemWidth
        self.content = content
    }
    
    // Init without index convenience
    init(items: [Item], spacing: CGFloat = 24, itemWidth: CGFloat = 180, @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.spacing = spacing
        self.itemWidth = itemWidth
        self.content = { item, _ in content(item) }
    }
    
    @State private var scrollPosition: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    private let tolerance: CGFloat = 10
    
    var body: some View {
        ZStack {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: spacing) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            content(item, index)
                                .id(item.id)
                        }
                    }
                    .padding(.leading, 268)
                    .padding(.trailing, 40)
                    .padding(.bottom, 20)
                    .background(GeometryReader { geo in
                        Color.clear
                            .preference(key: CarouselScrollOffsetKey.self, value: geo.frame(in: .named("carouselScrollContainer")).minX)
                            .onAppear { contentWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, newValue in contentWidth = newValue }
                    })
                }
                .coordinateSpace(name: "carouselScrollContainer")
                .onPreferenceChange(CarouselScrollOffsetKey.self) { value in
                    if let value = value {
                        self.scrollPosition = value
                    }
                }
                .background(GeometryReader { geo in
                    Color.clear.onAppear { containerWidth = geo.size.width }
                               .onChange(of: geo.size.width) { _, newValue in containerWidth = newValue }
                })
                
                // Left Arrow
                .overlay(alignment: .leading) {
                    if isHovering && scrollPosition < -tolerance {
                        Button(action: {
                            scrollLeft(proxy: proxy)
                        }) {
                            arrowButton(direction: "left")
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 268)
                        // Scroll content carries .padding(.bottom, 20), which pushes
                        // the overlay's vertical center below the card axis.
                        .offset(y: -10)
                        .transition(.opacity)
                    }
                }

                // Right Arrow
                .overlay(alignment: .trailing) {
                    if isHovering && (scrollPosition + contentWidth > containerWidth + tolerance) {
                        Button(action: {
                            scrollRight(proxy: proxy)
                        }) {
                            arrowButton(direction: "right")
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 10)
                        .offset(y: -10)
                        .transition(.opacity)
                    }
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                self.isHovering = hovering
            }
        }
    }
    
    private func arrowButton(direction: String) -> some View {
        Image(systemName: "chevron.\(direction)")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 64)
            .contentShape(Rectangle())
            .glassEffect(.regular.interactive(), in: .capsule)
    }
    
    private func scrollRight(proxy: ScrollViewProxy) {
        // Estimate current index based on scroll position + 40 padding
        // scrollPosition is negative. Distance scrolled = abs(scrollPosition - 40)
        let scrolledDistance = abs(scrollPosition - 40)
        let itemTotalWidth = itemWidth + spacing
        let currentIdx = Int(scrolledDistance / itemTotalWidth)
        
        let nextIndex = min(currentIdx + scrollStep, items.count - 1)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            proxy.scrollTo(nextIndex, anchor: .leading)
        }
    }
    
    private func scrollLeft(proxy: ScrollViewProxy) {
        let scrolledDistance = abs(scrollPosition - 40)
        let itemTotalWidth = itemWidth + spacing
        let currentIdx = Int(scrolledDistance / itemTotalWidth)
        
        let nextIndex = max(currentIdx - scrollStep, 0)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            proxy.scrollTo(nextIndex, anchor: .leading)
        }
    }
}

private struct CarouselScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}
