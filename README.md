<div align="center">

<img src="flux/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" width="128" height="128" alt="Flux App Icon" style="border-radius: 28px; box-shadow: 0 8px 24px rgba(0,0,0,0.35);" />

# Flux

### The Next-Generation Native Media Center for macOS

[![Platform](https://img.shields.io/badge/platform-macOS%2014.0%2B-blue?style=flat-square&logo=apple)](https://apple.com)
[![Swift](https://img.shields.io/badge/Swift-5.0-orange?style=flat-square&logo=swift)](https://swift.org)
[![Engine](https://img.shields.io/badge/player-libmpv-purple?style=flat-square)](https://mpv.io)
[![Updates](https://img.shields.io/badge/OTA%20Updates-Sparkle%202-green?style=flat-square)](https://sparkle-project.org)
[![License](https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square)](LICENSE)

*Crafted by [Entanglon](https://entanglon.pages.dev)*

<br />

</div>

**Flux** is a high-performance, modular media center designed exclusively for macOS. Built with pure SwiftUI and powered by the industry-grade `libmpv` engine, Flux delivers fluid animations, Apple TV-style glassmorphism, instant local stream racing, and hardware-accelerated 4K HDR playback.

---

## ✨ Key Features

### 💎 Liquid Glass Aesthetic
- **macOS-Native Design**: Built with pure SwiftUI, liquid glass materials, specular rim glints, and spring physics adhering to Apple’s latest design language.
- **Interactive Toggles & Sliders**: Fluid, rubber-banded segment controls and responsive player controls that stay completely out of your way during playback.

### ⚡ Autonomous Stream Racing (Flux Mode)
- **Local Client-Side Racing**: Discovers and evaluates stream candidates concurrently using 64KB ranged GET probes (`bytes=0-65535`) directly from your Mac to content CDNs.
- **Smart Health & Quality Scoring**: Prioritizes genuine 4K/1080p stream health, seeders, and low-latency hosts while completely filtering out dead links and mismatched releases.
- **Zero Cloud Proxying**: 100% of video queries and streams race on your machine—never routed through intermediary cloud servers.

### 🎬 Studio-Grade Video & Audio Engine
- **Powered by `libmpv`**: Plays nearly any video container, audio codec, or subtitle format natively without transcoding.
- **Hardware Acceleration & HDR**: Hardware decoding (`videotoolbox`) with tone mapping for HDR10 and Dolby Vision on Apple Silicon displays.
- **Acoustic Volume Curve & +200% Boost**: Perceptual volume mapping matching human hearing curves, with clean amplification up to 200% (+18 dB power boost) for quiet dialogue tracks.

### 🌐 Smart Language & Subtitles
- **Intelligent Track Selection**: Automatically pairs your preferred audio language with matching subtitles. If foreign audio is detected, English subtitles are auto-engaged.
- **OpenSubtitles v3 & Embedded Subtitles**: First-class subtitle lookup alongside instant embedded track switching.

### 📊 Stream Inspector HUD
- **Real-Time Technical Overlay**: Right-click the player anytime to reveal stream diagnostics: active video/audio codecs, hardware decoder state, resolution, bitrate, and live demuxer buffer telemetry.

### 🔄 Multi-Profile & Cloud Sync
- **Multi-Profile Support**: Distinct profiles with independent watch progress, continue watching rails, and custom settings.
- **Lightweight Cloud Sync**: Fast, end-to-end tokenized library synchronization powered by Cloudflare Workers—or stay 100% offline with zero login required.

### 🚀 Over-The-Air (OTA) Updates
- **Sparkle 2 Integration**: Silent update checking and one-click upgrades cryptographically signed with Ed25519 signatures.

---

## 🧩 Stremio Addon Compatibility

Flux features full compatibility with the Stremio Addon ecosystem. Any community or official Stremio addon can be installed directly into Flux:

- **Catalogs & Metadata**: Browse custom catalogues, anime indexes, YouTube channels, and niche movie lists.
- **Streams & Debrid**: Connect your favorite streaming providers and debrid services for autonomous stream racing and instant playback.
- **Subtitles**: Add multilingual subtitle providers (e.g., OpenSubtitles v3, SubScene).
- **Live TV & IPTV**: Stream live sports, news, and M3U-based TV channels right from the Flux sidebar.

### How to Install Addons
1. **One-Click Deep Links**: Clicking any `stremio://` addon link in your browser will automatically launch Flux and prompt you to install it with one click.
2. **Settings Menu**: Navigate to **Settings** (`Cmd + ,`) → **Addons**, paste any addon manifest URL (`manifest.json`), and click **Install**.
3. **Stremio Account Sync**: Sign in with your Stremio credentials in Settings to instantly sync your entire existing addon collection.

---

## 🛠️ Architecture & Tech Stack

- **UI Framework**: SwiftUI (macOS 14.0+)
- **Video Playback**: `MPVKit` (`libmpv`)
- **Metadata**: Cinemeta Catalog API & TMDB API (Optional user key)
- **Local Engine**: Embedded `StremioServer` daemon (`localhost:11470`)
- **Network Stack**: Apple Network framework TCP proxy (`localhost:51547`) & Swift Concurrency (`async`/`await`, `TaskGroup`)
- **Updates**: Sparkle 2.9+

---

## 💻 Building from Source

### Prerequisites
- Mac running **macOS Sonoma (14.0)** or newer
- **Xcode 16.0+** with Command Line Tools installed

### Setup & Compilation
1. **Clone the repository**:
   ```bash
   git clone https://github.com/entanglon/flux.git
   cd flux
   ```

2. **Open in Xcode**:
   ```bash
   open flux.xcodeproj
   ```

3. **Build and Run**:
   - Xcode will automatically resolve the Swift Package Manager dependencies (`MPVKit-GPL` and `Sparkle`).
   - Select the `flux` scheme and destination **My Mac**.
   - Press `Cmd + R` to build and run.

---

## ⚖️ Legal & Disclaimer

Flux is a media player frontend designed to organize, display, and play media files and streams provided by the user. 
- Flux does **not** host, index, scrape, cache, or distribute any copyrighted media or pirated content.
- Third-party addons are installed solely at the discretion and direction of the end user.
- Flux is distributed in good faith under the principle of substantial non-infringing use.

---

## 📄 License

Distributed under the MIT License. See [LICENSE](LICENSE) for details.
