import SwiftUI

/// Card-hosted auth (Settings sheet + any modal context).
/// The first-start gate uses `AuthFormView` directly — see AuthGateView.
struct AuthView: View {
    var startInSignUp: Bool = false
    var onCancel: (() -> Void)? = nil

    @State private var showForm = false

    init(startInSignUp: Bool = false, onCancel: (() -> Void)? = nil) {
        self.startInSignUp = startInSignUp
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ViewThatFits(in: .horizontal) {
                // Wide: branding left, form right
                HStack(spacing: 0) {
                    brandPanel
                        .frame(width: 270)
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1)
                    AuthFormView(
                        startInSignUp: startInSignUp,
                        showsGuestOption: false,
                        showsTitle: true,
                        onCancel: onCancel
                    )
                    .padding(.horizontal, 30)
                    .frame(width: 380)
                }
                .frame(height: 440)

                // Narrow: stacked
                VStack(spacing: 18) {
                    brandCompact
                    AuthFormView(
                        startInSignUp: startInSignUp,
                        showsTitle: false,
                        onCancel: onCancel
                    )
                }
                .padding(26)
            }
            .background(cardBackground)
            .opacity(showForm ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) { showForm = true }
        }
    }

    private var brandPanel: some View {
        VStack(spacing: 14) {
            Spacer()
            brandMark(size: 104, corner: 24)
            Text("Flux")
                .font(.system(size: 36, weight: .heavy))
                .foregroundStyle(.white)
            Text("Movies · Shows · Lists")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.5))
            Text("One account.\nEvery screen.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.05), Color.white.opacity(0.01)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private var brandCompact: some View {
        VStack(spacing: 10) {
            brandMark(size: 72, corner: 18)
            Text(isSignUpTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var isSignUpTitle: String {
        "Flux"
    }

    private func brandMark(size: CGFloat, corner: CGFloat) -> some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .shadow(color: .black.opacity(0.55), radius: 14, y: 7)
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.88))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.6), radius: 34, y: 14)
    }
}
