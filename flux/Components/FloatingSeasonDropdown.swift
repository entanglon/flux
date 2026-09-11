import SwiftUI
import Combine

/// Shared controller for the floating season dropdown.
/// DetailView owns the data; ContentView renders the panel at the root level
/// (above the rail and the glass sidebar) using the propagated button frame.
@MainActor
final class SeasonDropdownController: ObservableObject {
    static let shared = SeasonDropdownController()

    @Published var isOpen = false
    @Published var anchor: CGRect = .zero          // button frame in "rootSpace"
    @Published var seasons: [Season] = []
    @Published var selectedName: String = "Season 1"
    var onSelect: ((Season) -> Void)?

    func toggle() { isOpen.toggle() }
    func close() { isOpen = false }

    /// Estimated panel rect for outside-tap dismissal.
    var panelFrame: CGRect {
        CGRect(x: anchor.minX, y: anchor.maxY + 8,
               width: 210, height: CGFloat(seasons.count) * 34 + 16)
    }
}

/// Propagates the season button's frame (in "rootSpace") up to ContentView.
struct SeasonAnchorKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// The floating panel itself — rendered at ContentView's root overlay.
struct FloatingSeasonPanel: View {
    @ObservedObject var controller: SeasonDropdownController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(controller.seasons) { season in
                let isSelected = controller.selectedName == season.name
                Button {
                    controller.onSelect?(season)
                    controller.close()
                } label: {
                    HStack(spacing: 8) {
                        // Reserved checkmark column — no row shift
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 16)
                            .opacity(isSelected ? 1 : 0)

                        Text(season.localizedName)
                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.7))

                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 210)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }
}
