import SwiftUI

private struct CarouselLeadingMinXKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private struct CarouselTrailingMaxXKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private struct CarouselWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct CarouselView<Item, Content>: View where Item: Identifiable, Content: View {
    let items: [Item]
    let content: (Item, Int) -> Content
    let itemWidth: CGFloat
    let spacing: CGFloat
    
    @State private var isHovering: Bool = false
    @State private var scrollTargetIndex: Int = 0
    @State private var canScrollLeft: Bool = false
    @State private var canScrollRight: Bool = true
    @State private var containerWidth: CGFloat = 0
    @State private var coordinateSpaceID = UUID().uuidString
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
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        content(item, index)
                            .id(item.id)
                            .background {
                                if index == 0 || index == items.count - 1 {
                                    GeometryReader { geo in
                                        Color.clear
                                            .preference(
                                                key: CarouselLeadingMinXKey.self,
                                                value: index == 0 ? geo.frame(in: .named("carouselScroll_\(coordinateSpaceID)")).minX : nil
                                            )
                                            .preference(
                                                key: CarouselTrailingMaxXKey.self,
                                                value: index == items.count - 1 ? geo.frame(in: .named("carouselScroll_\(coordinateSpaceID)")).maxX : nil
                                            )
                                    }
                                }
                            }
                            .onAppear {
                                prefetchAhead(from: index)
                            }
                    }
                }
                .padding(.bottom, 20)
            }
            .coordinateSpace(name: "carouselScroll_\(coordinateSpaceID)")
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: CarouselWidthKey.self,
                        value: geo.size.width
                    )
                }
            )
            .onPreferenceChange(CarouselWidthKey.self) { width in
                containerWidth = width
            }
            .onPreferenceChange(CarouselLeadingMinXKey.self) { minX in
                guard let minX = minX else { return }
                let leftPossible = minX < 260
                if canScrollLeft != leftPossible {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        canScrollLeft = leftPossible
                    }
                }
                let scrolledCount = max(0, Int(round((268 - minX) / (itemWidth + spacing))))
                if abs(scrollTargetIndex - scrolledCount) >= 1 {
                    scrollTargetIndex = min(scrolledCount, max(0, items.count - 1))
                }
            }
            .onPreferenceChange(CarouselTrailingMaxXKey.self) { maxX in
                guard let maxX = maxX else { return }
                let rightPossible = containerWidth > 0 ? (maxX > containerWidth - 20) : (scrollTargetIndex < items.count - 1)
                if canScrollRight != rightPossible {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        canScrollRight = rightPossible
                    }
                }
            }
            .contentMargins(.leading, 268, for: .scrollContent)
            .contentMargins(.trailing, 40, for: .scrollContent)
            .scrollClipDisabled()
            // Left Arrow (offset -10: overlays center on the padded scrollview,
            // whose 20pt bottom padding sits arrows 10pt below card content)
            .overlay(alignment: .leading) {
                if isHovering && !items.isEmpty && (canScrollLeft || scrollTargetIndex > 0) {
                    Button(action: {
                        scrollLeft(proxy: proxy)
                    }) {
                        arrowButton("left")
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 268)
                    .offset(y: -10)
                    .transition(.opacity)
                }
            }
            // Right Arrow
            .overlay(alignment: .trailing) {
                if isHovering && !items.isEmpty && (canScrollRight || scrollTargetIndex < items.count - 1) {
                    Button(action: {
                        scrollRight(proxy: proxy)
                    }) {
                        arrowButton("right")
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                    .offset(y: -10)
                    .transition(.opacity)
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }
            .onChange(of: items.first?.id) { _, _ in
                scrollTargetIndex = 0
                canScrollLeft = false
                canScrollRight = true
                if let first = items.first {
                    proxy.scrollTo(first.id, anchor: .leading)
                }
            }
        }
    }
    
    private func arrowButton(_ direction: String) -> some View {
        Image(systemName: "chevron.\(direction)")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 64)
            .glassEffect(.regular.interactive(), in: .capsule)
    }
    
    private func scrollRight(proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }
        let newIndex = min(scrollTargetIndex + scrollStep, items.count - 1)
        scrollTargetIndex = newIndex
        let targetID = items[newIndex].id
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            proxy.scrollTo(targetID, anchor: .leading)
        }
    }
    
    private func scrollLeft(proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }
        let newIndex = max(scrollTargetIndex - scrollStep, 0)
        scrollTargetIndex = newIndex
        let targetID = items[newIndex].id
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            proxy.scrollTo(targetID, anchor: .leading)
        }
    }

    private func prefetchAhead(from index: Int) {
        guard !items.isEmpty else { return }
        let nextStart = index + 1
        let nextEnd = min(index + 3, items.count - 1)
        guard nextStart <= nextEnd else { return }

        // Direct cast only — runtime Mirror introspection on the scroll path is
        // notoriously expensive (allocates type metadata per card).
        for i in nextStart...nextEnd {
            let candidate = items[i]
            if let media = candidate as? MediaItem {
                if let u = media.posterURL ?? media.imageURL {
                    ImagePrefetcher.shared.prefetch(urls: [u])
                }
            } else if let channel = candidate as? Channel {
                if let u = channel.logoURL {
                    ImagePrefetcher.shared.prefetch(urls: [u])
                }
            }
        }
    }
}
