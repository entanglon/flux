import SwiftUI

/// First-start identity gate: full-page split — branding left, form card right.
struct AuthGateView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            HStack(spacing: 0) {
                // Left half — branding
                VStack(spacing: 20) {
                    Spacer()
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 128, height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.65), radius: 20, y: 10)

                    Text("Flux")
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundStyle(.white)

                    Text("Your movies, shows, and lists — everywhere.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Right half — form card
                ZStack {
                    Color.white.opacity(0.03)

                    VStack(spacing: 0) {
                        Spacer()
                        AuthFormView(
                            startInSignUp: false,
                            showsGuestOption: true,
                            showsTitle: true,
                            isModal: false,
                            onCancel: nil
                        )
                        .padding(44)
                        .frame(width: 420, height: 480, alignment: .center)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                )
                        )
                        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
