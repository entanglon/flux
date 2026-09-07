import SwiftUI

/// Sheet-hosted auth modal (Settings sheet + any modal context).
/// The first-start gate uses `AuthGateView` directly.
struct AuthView: View {
    @Environment(\.dismiss) private var dismiss
    var startInSignUp: Bool = false
    var onCancel: (() -> Void)? = nil

    @State private var isHoveringClose = false

    init(startInSignUp: Bool = false, onCancel: (() -> Void)? = nil) {
        self.startInSignUp = startInSignUp
        self.onCancel = onCancel
    }

    private func handleDismiss() {
        dismiss()
        onCancel?()
    }

    var body: some View {
        VStack(spacing: 16) {
            brandCompact

            AuthFormView(
                startInSignUp: startInSignUp,
                showsGuestOption: false,
                showsTitle: false,
                isModal: true,
                onCancel: nil
            )
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(width: 380, height: 490)
        .background(Color(red: 0.11, green: 0.12, blue: 0.15))
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            Button(action: handleDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(isHoveringClose ? 0.75 : 0.35))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringClose = $0 }
            .padding([.top, .trailing], 14)
            .help("Close (Esc)")
            .keyboardShortcut(.cancelAction)
        }
        .onChange(of: AuthManager.shared.currentUser) { _, user in
            if user != nil {
                handleDismiss()
            }
        }
    }

    private var brandCompact: some View {
        VStack(spacing: 8) {
            brandMark(size: 64, corner: 16)
            Text("Flux")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private func brandMark(size: CGFloat, corner: CGFloat) -> some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
    }
}
