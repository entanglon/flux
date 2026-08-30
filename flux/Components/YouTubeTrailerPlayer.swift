import SwiftUI
import WebKit

// MARK: - Native WebKit YouTube Embed View
struct YouTubeWebView: NSViewRepresentable {
    let videoKey: String
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // Transparent background
        loadYouTubeVideo(in: webView)
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Only reload if the video key has changed
        if context.coordinator.currentKey != videoKey {
            context.coordinator.currentKey = videoKey
            loadYouTubeVideo(in: nsView)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(videoKey: videoKey)
    }
    
    class Coordinator {
        var currentKey: String
        init(videoKey: String) {
            self.currentKey = videoKey
        }
    }
    
    private func loadYouTubeVideo(in webView: WKWebView) {
        let embedHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { box-sizing: border-box; }
                body, html {
                    margin: 0;
                    padding: 0;
                    width: 100%;
                    height: 100%;
                    overflow: hidden;
                    background-color: #000000;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                }
                iframe {
                    border: none;
                    width: 100%;
                    height: 100%;
                    position: absolute;
                    top: 0;
                    left: 0;
                }
            </style>
        </head>
        <body>
            <iframe 
                src="https://www.youtube-nocookie.com/embed/\(videoKey)?autoplay=1&rel=0&modestbranding=1&playsinline=1&enablejsapi=1&fs=1" 
                allow="autoplay; encrypted-media; picture-in-picture; fullscreen" 
                allowfullscreen>
            </iframe>
        </body>
        </html>
        """
        webView.loadHTMLString(embedHTML, baseURL: URL(string: "https://www.youtube-nocookie.com"))
    }
}

// MARK: - In-App Cinema Trailer Theater Modal
struct TrailerPlayerModal: View {
    let video: TMDBVideo
    let title: String
    let onDismiss: () -> Void
    
    @State private var isVisible = false
    
    var body: some View {
        ZStack {
            // 1. Cinema Dimmed Backdrop
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture {
                    closeModal()
                }
            
            // 2. Main Theater Container
            VStack(spacing: 14) {
                // Header Bar
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("TRAILER THEATER")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(Color.cyan)
                            
                            Text("•")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.white.opacity(0.4))
                            
                            Text(video.type)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.7))
                        }
                        
                        Text("\(title) — \(video.name)")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    // Close Button (Liquid Glass)
                    Button {
                        closeModal()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close Trailer (Esc)")
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 6)
                
                // 16:9 HD Video Player Frame
                ZStack {
                    YouTubeWebView(videoKey: video.key)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.3), .white.opacity(0.08)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                        .shadow(color: .black.opacity(0.75), radius: 30, x: 0, y: 15)
                }
                .aspectRatio(16/9, contentMode: .fit)
                .frame(maxWidth: 960, maxHeight: 540)
            }
            .padding(24)
            .frame(maxWidth: 1040)
            .scaleEffect(isVisible ? 1.0 : 0.94)
            .opacity(isVisible ? 1.0 : 0.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isVisible)
        }
        .onAppear {
            isVisible = true
        }
    }
    
    private func closeModal() {
        withAnimation(.easeOut(duration: 0.2)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDismiss()
        }
    }
}
