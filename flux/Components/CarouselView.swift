import SwiftUI

struct CarouselView<Item, Content>: View where Item: Identifiable, Content: View {
    let items: [Item]
    let content: (Item, Int) -> Content
    let itemWidth: CGFloat
    let spacing: CGFloat
    
    @State private var isHovering: Bool = false
    @State private var scrollTargetIndex: Int = 0
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
                            .onAppear {
                                prefetchAhead(from: index)
                            }
                    }
                }
                .padding(.leading, 268)
                .padding(.trailing, 40)
                .padding(.bottom, 20)
            }
            // Left Arrow
            .overlay(alignment: .leading) {
                if isHovering && scrollTargetIndex > 0 {
                    Button(action: {
                        scrollLeft(proxy: proxy)
                    }) {
                        arrowButton("left")
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 268)
                    .transition(.opacity)
                }
            }
            // Right Arrow
            .overlay(alignment: .trailing) {
                if isHovering && scrollTargetIndex < items.count - 1 {
                    Button(action: {
                        scrollRight(proxy: proxy)
                    }) {
                        arrowButton("right")
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                    .transition(.opacity)
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }
            .onChange(of: items.first?.id) { _, _ in
                scrollTargetIndex = 0
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
        scrollTargetIndex = min(scrollTargetIndex + scrollStep, items.count - 1)
        let targetID = items[scrollTargetIndex].id
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            proxy.scrollTo(targetID, anchor: .leading)
        }
    }
    
    private func scrollLeft(proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }
        scrollTargetIndex = max(scrollTargetIndex - scrollStep, 0)
        let targetID = items[scrollTargetIndex].id
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
        // far more expensive than the prefetch it serves. Non-MediaItem rows
        // (genres, platforms) use local assets/text and need no prefetch.
        var urls: [URL?] = []
        for i in nextStart...nextEnd {
            if let media = items[i] as? MediaItem {
                urls.append(media.posterURL ?? media.imageURL ?? media.backdropURL)
            }
        }
        ImagePrefetcher.shared.prefetch(urls: urls, maxDimension: itemWidth * 1.5)
    }
}

public struct CarouselScrollBounds: Equatable {
    public var canScrollLeft: Bool
    public var canScrollRight: Bool
    public init(canScrollLeft: Bool, canScrollRight: Bool) {
        self.canScrollLeft = canScrollLeft
        self.canScrollRight = canScrollRight
    }
}
