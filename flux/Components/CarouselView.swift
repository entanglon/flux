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
    
    @State private var canScrollLeft: Bool = false
    @State private var canScrollRight: Bool = false
    @State private var scrollTargetIndex: Int = 0
    @State private var containerWidth: CGFloat = 0
    
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
                    .background(
                        GeometryReader { contentGeo in
                            Color.clear.preference(
                                key: CarouselBoundsPreferenceKey.self,
                                value: CarouselScrollBounds(
                                    canScrollLeft: contentGeo.frame(in: .named("carouselScrollContainer")).minX < -15,
                                    canScrollRight: contentGeo.frame(in: .named("carouselScrollContainer")).maxX > containerWidth + 15
                                )
                            )
                        }
                    )
                }
                .coordinateSpace(name: "carouselScrollContainer")
                .onPreferenceChange(CarouselBoundsPreferenceKey.self) { bounds in
                    if self.canScrollLeft != bounds.canScrollLeft {
                        self.canScrollLeft = bounds.canScrollLeft
                    }
                    if self.canScrollRight != bounds.canScrollRight {
                        self.canScrollRight = bounds.canScrollRight
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.onAppear { containerWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, newValue in containerWidth = newValue }
                    }
                )
                
                // Left Arrow
                .overlay(alignment: .leading) {
                    if isHovering && canScrollLeft {
                        Button(action: {
                            scrollLeft(proxy: proxy)
                        }) {
                            arrowButton(direction: "left")
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 268)
                        .offset(y: -10)
                        .transition(.opacity)
                    }
                }

                // Right Arrow
                .overlay(alignment: .trailing) {
                    if isHovering && canScrollRight {
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
        guard !items.isEmpty else { return }
        scrollTargetIndex = min(scrollTargetIndex + scrollStep, items.count - 1)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            proxy.scrollTo(items[scrollTargetIndex].id, anchor: .leading)
        }
    }
    
    private func scrollLeft(proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }
        scrollTargetIndex = max(scrollTargetIndex - scrollStep, 0)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            proxy.scrollTo(items[scrollTargetIndex].id, anchor: .leading)
        }
    }
}

struct CarouselScrollBounds: Equatable {
    let canScrollLeft: Bool
    let canScrollRight: Bool
}

private struct CarouselBoundsPreferenceKey: PreferenceKey {
    static var defaultValue = CarouselScrollBounds(canScrollLeft: false, canScrollRight: true)
    static func reduce(value: inout CarouselScrollBounds, nextValue: () -> CarouselScrollBounds) {
        value = nextValue()
    }
}
