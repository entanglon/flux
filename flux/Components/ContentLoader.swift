import SwiftUI

/// Full-viewport loading indicator, centered in the visible content area.
/// Use as `.overlay { if isLoading { ContentLoader() } }` on the page's
/// ScrollView — the overlay fills the scroll viewport exactly, so centering
/// is always correct (clears the 268pt sidebar via leading padding).
struct ContentLoader: View {
    var label: String? = nil

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            if let label {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.leading, 268)
        .padding(.trailing, 40)
    }
}
