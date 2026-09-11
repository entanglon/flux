import SwiftUI

struct KeyboardShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct ShortcutItem: Identifiable {
        let id = UUID()
        let action: String
        let keys: [String]
    }

    private let playbackShortcuts: [ShortcutItem] = [
        ShortcutItem(action: "Play / Pause", keys: ["Space"]),
        ShortcutItem(action: "Seek 10s Backward", keys: ["←"]),
        ShortcutItem(action: "Seek 10s Forward", keys: ["→"]),
        ShortcutItem(action: "Seek 1 Minute", keys: ["⇧", "← / →"]),
        ShortcutItem(action: "Volume Up / Down", keys: ["↑ / ↓"]),
        ShortcutItem(action: "Toggle Mute", keys: ["M"]),
        ShortcutItem(action: "Toggle Fullscreen", keys: ["F"]),
        ShortcutItem(action: "Cycle Subtitles", keys: ["S"]),
        ShortcutItem(action: "Cycle Audio Tracks", keys: ["A"]),
        ShortcutItem(action: "Choose Stream / Sources", keys: ["O"]),
        ShortcutItem(action: "Show / Hide Controls", keys: ["C"]),
        ShortcutItem(action: "Exit Fullscreen / Dismiss", keys: ["Esc"]),
    ]

    private let navigationShortcuts: [ShortcutItem] = [
        ShortcutItem(action: "Go to Home", keys: ["⌘", "1"]),
        ShortcutItem(action: "Go to Movies", keys: ["⌘", "2"]),
        ShortcutItem(action: "Go to TV Shows", keys: ["⌘", "3"]),
        ShortcutItem(action: "Go to Trending", keys: ["⌘", "4"]),
        ShortcutItem(action: "Search Catalog", keys: ["⌘", "F"]),
        ShortcutItem(action: "Refresh Catalogs", keys: ["⌘", "R"]),
        ShortcutItem(action: "Preferences / Settings", keys: ["⌘", ","]),
        ShortcutItem(action: "Keyboard Shortcuts", keys: ["⌘", "/"]),
        ShortcutItem(action: "Help & Documentation", keys: ["⌘", "?"]),
        ShortcutItem(action: "Close Window", keys: ["⌘", "W"]),
        ShortcutItem(action: "Quit Flux", keys: ["⌘", "Q"]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "command.square.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard Shortcuts".localized)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Control playback and navigate seamlessly.".localized)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(Color.white.opacity(0.1))

            // Two-column shortcuts list
            HStack(alignment: .top, spacing: 24) {
                // Column 1: Playback
                VStack(alignment: .leading, spacing: 10) {
                    Label("Playback Controls".localized, systemImage: "play.tv.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.cyan)
                        .padding(.bottom, 2)

                    ForEach(playbackShortcuts) { item in
                        shortcutRow(item: item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().background(Color.white.opacity(0.08))

                // Column 2: Navigation
                VStack(alignment: .leading, spacing: 10) {
                    Label("Navigation & Global".localized, systemImage: "sidebar.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.blue)
                        .padding(.bottom, 2)

                    ForEach(navigationShortcuts) { item in
                        shortcutRow(item: item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Spacer(minLength: 0)

            Divider().background(Color.white.opacity(0.1))

            // Footer
            HStack {
                Text("Press Esc or click anywhere outside to close.".localized)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done".localized) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(width: 620, height: 510)
        .background(Color(red: 0.11, green: 0.12, blue: 0.15))
        .preferredColorScheme(.dark)
    }

    private func shortcutRow(item: ShortcutItem) -> some View {
        HStack {
            Text(item.action.localized)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))

            Spacer()

            HStack(spacing: 4) {
                ForEach(item.keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.12))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.white.opacity(0.2), lineWidth: 0.6)
                        )
                }
            }
        }
    }
}
