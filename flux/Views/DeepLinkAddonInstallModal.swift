import SwiftUI

// MARK: - Deep Link Addon Installation Modal (Floating Glass UI)

struct DeepLinkAddonInstallModal: View {
    @ObservedObject var addonManager = AddonManager.shared
    
    var body: some View {
        if addonManager.showDeepLinkModal, let manifest = addonManager.pendingDeepLinkManifest {
            ZStack {
                // Dimmed Backdrop Blur
                Color.black.opacity(0.65)
                    .ignoresSafeArea()
                    .onTapGesture {
                        addonManager.dismissDeepLinkModal()
                    }
                
                // Floating Glass Card
                VStack(alignment: .leading, spacing: 18) {
                    // Header with Logo + Name + Dismiss
                    HStack(alignment: .top, spacing: 14) {
                        // Addon Logo
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 52, height: 52)
                            
                            if let logoStr = manifest.logo ?? manifest.icon, let url = URL(string: logoStr) {
                                CachedImage(url: url, maxDimension: 120) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 42, height: 42)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    default:
                                        fallbackLogo(name: manifest.name)
                                    }
                                }
                            } else {
                                fallbackLogo(name: manifest.name)
                            }
                        }
                        .frame(width: 52, height: 52)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(manifest.name)
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                
                                if let ver = manifest.version {
                                    Text("v\(ver)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.6))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                            }
                            
                            Text("External Addon Installation Request")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        
                        Spacer()
                        
                        Button(action: { addonManager.dismissDeepLinkModal() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // Description
                    if let desc = manifest.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(3)
                            .padding(.vertical, 2)
                    }
                    
                    // Permissions & Requested Resources
                    VStack(alignment: .leading, spacing: 8) {
                        Text("REQUESTED CAPABILITIES")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.45))
                            .tracking(0.8)
                        
                        HStack(spacing: 8) {
                            if let resources = manifest.resources, !resources.isEmpty {
                                ForEach(resources, id: \.self) { res in
                                    HStack(spacing: 4) {
                                        Image(systemName: iconForResource(res))
                                            .font(.system(size: 10))
                                        Text(res.capitalized)
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.08))
                                    .foregroundColor(.white.opacity(0.85))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                            } else {
                                Text("Standard Media Provider")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            Spacer()
                        }
                    }
                    
                    // Manifest Source URL
                    if let urlStr = addonManager.pendingDeepLinkURL {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                            Text(urlStr)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    
                    if let error = addonManager.deepLinkError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                            Text(error)
                                .font(.system(size: 11.5))
                        }
                        .foregroundColor(.red)
                    }
                    
                    Divider()
                        .background(Color.white.opacity(0.08))
                    
                    // Action Buttons (Liquid Glass)
                    HStack(spacing: 12) {
                        Button("Cancel") {
                            addonManager.dismissDeepLinkModal()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7.5)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                        
                        Spacer()
                        
                        Button(action: {
                            Task {
                                await addonManager.confirmDeepLinkInstallation()
                            }
                        }) {
                            HStack(spacing: 6) {
                                if addonManager.isInstallingDeepLink {
                                    ProgressView()
                                        .scaleEffect(0.65)
                                        .tint(.white)
                                } else {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 12.5, weight: .bold))
                                }
                                Text(addonManager.isInstallingDeepLink ? "Installing…" : "Install Addon")
                                    .font(.system(size: 12.5, weight: .bold))
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 7.5)
                            .background(Color.white.opacity(0.18))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                            .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                        .disabled(addonManager.isInstallingDeepLink)
                    }
                }
                .padding(24)
                .frame(width: 480)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.95))
                        .shadow(color: .black.opacity(0.7), radius: 32, x: 0, y: 16)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.25), .white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.94).combined(with: .opacity),
                    removal: .scale(scale: 0.96).combined(with: .opacity)
                ))
            }
            .zIndex(100)
        }
    }
    
    private func fallbackLogo(name: String) -> some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.9))
    }
    
    private func iconForResource(_ resource: String) -> String {
        switch resource.lowercased() {
        case "stream": return "play.circle.fill"
        case "subtitles": return "captions.bubble.fill"
        case "catalog": return "square.grid.2x2.fill"
        case "meta": return "info.circle.fill"
        default: return "puzzlepiece.extension.fill"
        }
    }
}
