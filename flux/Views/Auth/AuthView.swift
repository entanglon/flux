import SwiftUI

/// Card-hosted auth (Settings sheet + any modal context).
/// The first-start gate uses `AuthFormView` directly — see AuthGateView.
struct AuthView: View {
    @Environment(\.dismiss) private var dismiss
    var startInSignUp: Bool = false
    var onCancel: (() -> Void)? = nil

    @State private var showForm = false
    @State private var isHoveringClose = false
    @State private var isHoveringCloseTrailing = false

    init(startInSignUp: Bool = false, onCancel: (() -> Void)? = nil) {
        self.startInSignUp = startInSignUp
        self.onCancel = onCancel
    }

    private func handleDismiss() {
        dismiss()
        onCancel?()
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
                        onCancel: handleDismiss
                    )
                    .padding(.horizontal, 30)
                    .frame(width: 380)
                }
                .frame(height: 480)

                // Narrow: stacked
                VStack(spacing: 16) {
                    brandCompact
                    AuthFormView(
                        startInSignUp: startInSignUp,
                        showsTitle: false,
                        onCancel: handleDismiss
                    )
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(width: 380)
            }
            .background(cardBackground)
            .overlay(alignment: .topLeading) {
                Button(action: handleDismiss) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 1.0, green: 0.36, blue: 0.34))
                            .frame(width: 13, height: 13)
                            .overlay(
                                Circle()
                                    .stroke(Color.black.opacity(0.2), lineWidth: 0.5)
                            )
                        Image(systemName: "xmark")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(Color.black.opacity(isHoveringClose ? 0.75 : 0))
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringClose = $0 }
                .padding([.top, .leading], 12)
                .help("Close (Esc)")
            }
            .overlay(alignment: .topTrailing) {
                Button(action: handleDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(isHoveringCloseTrailing ? 0.65 : 0.28))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringCloseTrailing = $0 }
                .padding([.top, .trailing], 12)
                .help("Close (Esc)")
            }
            .opacity(showForm ? 1 : 0)
        }
        .onChange(of: AuthManager.shared.currentUser) { _, user in
            if user != nil {
                handleDismiss()
            }
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
