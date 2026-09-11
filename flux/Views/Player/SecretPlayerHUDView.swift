import SwiftUI

enum DelayUnit: String, CaseIterable {
    case seconds = "sec"
    case milliseconds = "ms"
}

struct SecretPlayerHUDView: View {
    var mpv: MPVController
    var onClose: () -> Void

    enum Section: String, CaseIterable, Identifiable {
        case diagnostics = "Stats"
        case subtitles = "Subtitles"
        case audio = "Audio"
        case video = "Video"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .diagnostics: return "Stats for Nerds"
            case .subtitles: return "Subtitles Calibration"
            case .audio: return "Audio Sync & Boost"
            case .video: return "Video Filters & Shaders"
            }
        }

        var subtitle: String {
            switch self {
            case .diagnostics: return "Live stream telemetry, hardware decoder & demuxer cache"
            case .subtitles: return "Timing offset sync, font sizing & screen position"
            case .audio: return "Audio-video sync, dialogue normalization & dynamic range"
            case .video: return "Aspect ratio override, deband shader & color grading"
            }
        }

        var icon: String {
            switch self {
            case .diagnostics: return "chart.xyaxis.line"
            case .subtitles: return "captions.bubble.fill"
            case .audio: return "waveform"
            case .video: return "slider.horizontal.3"
            }
        }
    }

    @State private var activeSection: Section = .diagnostics
    @State private var diagnostics = PlaybackDiagnostics()
    @State private var timer: Timer? = nil

    // Performance-isolated local state (prevents main-thread rendering lag from player position ticks)
    @State private var subtitleDelay: Double = 0.0
    @State private var subtitleScale: Double = 1.0
    @State private var subtitlePos: Double = 100.0
    @State private var customSubtitleDelayInput: String = ""
    @State private var subtitleUnit: DelayUnit = .seconds

    @State private var audioDelay: Double = 0.0
    @State private var customAudioDelayInput: String = ""
    @State private var audioUnit: DelayUnit = .seconds
    @State private var isDialogueBoostEnabled: Bool = false
    @State private var volume: Double = 1.0

    @State private var videoAspect: String = "auto"
    @State private var isDebandEnabled: Bool = false
    @State private var contrast: Double = 0.0
    @State private var brightness: Double = 0.0
    @State private var saturation: Double = 0.0

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider().background(Color.white.opacity(0.18))
            contentView
        }
        .frame(width: 580, height: 440)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.26), Color.white.opacity(0.09)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 28, x: 0, y: 14)
        .onAppear {
            syncStateFromMPV()
            if activeSection == .diagnostics {
                refreshDiagnostics()
                startDiagnosticsTimer()
            }
        }
        .onChange(of: activeSection) { _, newSec in
            if newSec == .diagnostics {
                refreshDiagnostics()
                startDiagnosticsTimer()
            } else {
                stopDiagnosticsTimer()
            }
        }
        .onDisappear {
            stopDiagnosticsTimer()
        }
    }

    private func syncStateFromMPV() {
        self.subtitleDelay = mpv.subtitleDelay
        self.customSubtitleDelayInput = String(format: "%.2f", mpv.subtitleDelay)
        self.subtitleScale = mpv.subtitleScale
        self.subtitlePos = mpv.subtitlePos
        self.audioDelay = mpv.audioDelay
        self.customAudioDelayInput = String(format: "%.2f", mpv.audioDelay)
        self.isDialogueBoostEnabled = mpv.isDialogueBoostEnabled
        self.volume = mpv.volume
        self.videoAspect = mpv.videoAspect
        self.isDebandEnabled = mpv.isDebandEnabled
        self.contrast = mpv.contrast
        self.brightness = mpv.brightness
        self.saturation = mpv.saturation
    }

    private func startDiagnosticsTimer() {
        stopDiagnosticsTimer()
        guard activeSection == .diagnostics else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak mpv] _ in
            guard let mpv = mpv else { return }
            Task.detached(priority: .utility) { [weak mpv] in
                guard let mpv = mpv else { return }
                let d = mpv.getPlaybackDiagnostics()
                await MainActor.run {
                    self.diagnostics = d
                }
            }
        }
    }

    private func stopDiagnosticsTimer() {
        timer?.invalidate()
        timer = nil
    }

    private var headerView: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.cyan)

                Text("Playback Tuning")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }

            Spacer()

            tabSwitcher

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.04))
    }

    private var tabSwitcher: some View {
        HStack(spacing: 5) {
            ForEach(Section.allCases) { sec in
                Button {
                    activeSection = sec
                } label: {
                    Image(systemName: sec.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(activeSection == sec ? Color.cyan.opacity(0.35) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(activeSection == sec ? Color.cyan.opacity(0.6) : Color.clear, lineWidth: 1)
                        )
                        .foregroundStyle(activeSection == sec ? .white : .white.opacity(0.65))
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.15), value: activeSection)
                .help(sec.title)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    private var contentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Active Section Header Banner
                HStack(spacing: 8) {
                    Image(systemName: activeSection.icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activeSection.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                        Text(activeSection.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)

                Divider().background(Color.white.opacity(0.10))

                Group {
                    switch activeSection {
                    case .diagnostics:
                        diagnosticsView
                    case .subtitles:
                        subtitlesView
                    case .audio:
                        audioView
                    case .video:
                        videoView
                    }
                }
                .id(activeSection)
                .transition(.opacity)
            }
            .padding(20)
        }
        .animation(.easeInOut(duration: 0.12), value: activeSection)
    }

    private func refreshDiagnostics() {
        Task.detached(priority: .utility) { [weak mpv] in
            guard let mpv = mpv else { return }
            let d = mpv.getPlaybackDiagnostics()
            await MainActor.run {
                self.diagnostics = d
            }
        }
    }

    // MARK: - Section 1: Diagnostics (Stats for Nerds)

    private var cleanVideoCodec: String {
        let raw = diagnostics.videoCodec.uppercased()
        if raw.contains("H.264") || raw.contains("AVC") { return "H.264 / AVC" }
        if raw.contains("HEVC") || raw.contains("H.265") { return "HEVC / H.265" }
        if raw.contains("AV1") { return "AV1" }
        if raw.contains("VP9") { return "VP9" }
        return raw.isEmpty ? "Unknown" : raw
    }

    private var cleanAudioCodec: String {
        let raw = diagnostics.audioCodec.uppercased()
        if raw.contains("EAC3") || raw.contains("E-AC-3") || raw.contains("ATSC A/52B") { return "E-AC-3 (Dolby Digital Plus)" }
        if raw.contains("AC3") { return "AC-3 (Dolby Digital)" }
        if raw.contains("AAC") { return "AAC" }
        if raw.contains("OPUS") { return "Opus" }
        if raw.contains("FLAC") { return "FLAC" }
        if raw.contains("TRUEHD") { return "TrueHD" }
        if raw.contains("DTS") { return "DTS" }
        return raw.isEmpty ? "Unknown" : raw
    }

    private var diagnosticsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            diagnosticRow(label: "Video Codec / Format", value: cleanVideoCodec)
            diagnosticRow(label: "Video Resolution", value: diagnostics.resolution)
            diagnosticRow(label: "Framerate", value: diagnostics.fps > 0 ? String(format: "%.2f fps", diagnostics.fps) : "Unknown")
            diagnosticRow(label: "Hardware Decoder", value: diagnostics.hwDecoder, badgeColor: diagnostics.hwDecoder != "software" && diagnostics.hwDecoder != "no" ? .green : .orange)
            diagnosticRow(label: "Dropped Video Frames", value: "\(diagnostics.droppedFrames)", badgeColor: diagnostics.droppedFrames > 200 ? .orange : .secondary)

            Divider().background(Color.white.opacity(0.1))

            diagnosticRow(label: "Audio Codec", value: cleanAudioCodec)
            diagnosticRow(label: "Demuxer Buffer Cache", value: String(format: "%.1f seconds", diagnostics.cacheBufferSeconds))
            if diagnostics.videoBitrate > 0 {
                diagnosticRow(label: "Video Bitrate", value: String(format: "%.1f kbps", diagnostics.videoBitrate))
            }
            if diagnostics.audioBitrate > 0 {
                diagnosticRow(label: "Audio Bitrate", value: String(format: "%.1f kbps", diagnostics.audioBitrate))
            }
        }
    }

    private func diagnosticRow(label: String, value: String, badgeColor: Color? = nil) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(badgeColor ?? .white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
        }
    }

    // MARK: - Section 2: Subtitles Calibration

    private var subtitlesView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Delay Calibration
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Subtitle Delay Sync")
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Text(String(format: "%+.2f seconds", subtitleDelay))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(abs(subtitleDelay) > 0.01 ? .cyan : .white.opacity(0.6))
                }

                Text("Adjust when dialogue and subtitles are out of synchronization")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    calibrationButton("-500ms") { setSubtitleOffset(subtitleDelay - 0.5) }
                    calibrationButton("-100ms") { setSubtitleOffset(subtitleDelay - 0.1) }
                    calibrationButton("-50ms") { setSubtitleOffset(subtitleDelay - 0.05) }

                    Button {
                        setSubtitleOffset(0.0)
                    } label: {
                        Text("Reset")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    calibrationButton("+50ms") { setSubtitleOffset(subtitleDelay + 0.05) }
                    calibrationButton("+100ms") { setSubtitleOffset(subtitleDelay + 0.1) }
                    calibrationButton("+500ms") { setSubtitleOffset(subtitleDelay + 0.5) }
                }

                // Custom Subtitle Delay Input Bar
                HStack(spacing: 10) {
                    Text("Custom Offset:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))

                    HStack(spacing: 6) {
                        TextField("e.g. -1.25", text: $customSubtitleDelayInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(width: 100)
                            .background(Color.white.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 0.75)
                            )
                            .onSubmit {
                                applyCustomSubtitleDelay()
                            }

                        Picker("", selection: $subtitleUnit) {
                            Text("sec").tag(DelayUnit.seconds)
                            Text("ms").tag(DelayUnit.milliseconds)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 85)

                        Button {
                            applyCustomSubtitleDelay()
                        } label: {
                            Text("Apply")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Color.cyan)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }

            Divider().background(Color.white.opacity(0.15))

            // Subtitle Scale
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Subtitle Size")
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Text("\(Int(subtitleScale * 100))%")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }

                Slider(
                    value: Binding(
                        get: { subtitleScale },
                        set: { newVal in
                            let rounded = (newVal * 20.0).rounded() / 20.0
                            if subtitleScale != rounded {
                                subtitleScale = rounded
                                mpv.setSubtitleScale(rounded)
                            }
                        }
                    ),
                    in: 0.6...1.8,
                    step: 0.05
                )
                .tint(.cyan)
            }

            Divider().background(Color.white.opacity(0.15))

            // Subtitle Position
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Vertical Position")
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Text("\(Int(subtitlePos))%")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }

                Slider(
                    value: Binding(
                        get: { subtitlePos },
                        set: { newVal in
                            let rounded = newVal.rounded()
                            if subtitlePos != rounded {
                                subtitlePos = rounded
                                mpv.setSubtitlePos(rounded)
                            }
                        }
                    ),
                    in: 50...100,
                    step: 1.0
                )
                .tint(.cyan)
            }
        }
    }

    private func setSubtitleOffset(_ val: Double) {
        let rounded = (val * 20.0).rounded() / 20.0
        subtitleDelay = rounded
        customSubtitleDelayInput = String(format: "%.2f", rounded)
        mpv.setSubtitleDelay(rounded)
    }

    private func applyCustomSubtitleDelay() {
        let trimmed = customSubtitleDelayInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let raw = Double(trimmed) else { return }
        let inSeconds: Double
        if subtitleUnit == .milliseconds || abs(raw) >= 50.0 {
            inSeconds = raw / 1000.0
        } else {
            inSeconds = raw
        }
        let rounded = (inSeconds * 100.0).rounded() / 100.0
        subtitleDelay = rounded
        customSubtitleDelayInput = String(format: "%.2f", rounded)
        mpv.setSubtitleDelay(rounded)
    }

    // MARK: - Section 3: Audio Sync & Boost

    private var audioView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Audio Delay Sync
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Audio Delay Sync")
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Text(String(format: "%+.2f seconds", audioDelay))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(abs(audioDelay) > 0.01 ? .cyan : .white.opacity(0.6))
                }

                Text("Fix Bluetooth latency or audio-video desync")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    calibrationButton("-200ms") { setAudioOffset(audioDelay - 0.2) }
                    calibrationButton("-100ms") { setAudioOffset(audioDelay - 0.1) }
                    calibrationButton("-50ms") { setAudioOffset(audioDelay - 0.05) }

                    Button {
                        setAudioOffset(0.0)
                    } label: {
                        Text("Reset")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    calibrationButton("+50ms") { setAudioOffset(audioDelay + 0.05) }
                    calibrationButton("+100ms") { setAudioOffset(audioDelay + 0.1) }
                    calibrationButton("+200ms") { setAudioOffset(audioDelay + 0.2) }
                }

                // Custom Audio Delay Input Bar
                HStack(spacing: 10) {
                    Text("Custom Offset:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))

                    HStack(spacing: 6) {
                        TextField("e.g. +0.25", text: $customAudioDelayInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(width: 100)
                            .background(Color.white.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 0.75)
                            )
                            .onSubmit {
                                applyCustomAudioDelay()
                            }

                        Picker("", selection: $audioUnit) {
                            Text("sec").tag(DelayUnit.seconds)
                            Text("ms").tag(DelayUnit.milliseconds)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 85)

                        Button {
                            applyCustomAudioDelay()
                        } label: {
                            Text("Apply")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Color.cyan)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }

            Divider().background(Color.white.opacity(0.15))

            // Dialogue Boost
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dialogue Boost / Night Mode")
                        .font(.system(size: 14, weight: .bold))
                    Text("Dynamic range normalizer: boosts soft whisper dialogue and compresses loud explosions")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { isDialogueBoostEnabled },
                    set: { newVal in
                        isDialogueBoostEnabled = newVal
                        mpv.toggleDialogueBoost()
                    }
                ))
                .toggleStyle(.switch)
                .tint(.cyan)
                .labelsHidden()
            }

            Divider().background(Color.white.opacity(0.15))

            // Volume Boost status
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Volume Level")
                        .font(.system(size: 14, weight: .bold))
                    Text("Boosted audio amplifier up to 200%")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(volume * 100))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(volume > 1.0 ? .orange : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
            }
        }
    }

    private func setAudioOffset(_ val: Double) {
        let rounded = (val * 20.0).rounded() / 20.0
        audioDelay = rounded
        customAudioDelayInput = String(format: "%.2f", rounded)
        mpv.setAudioDelay(rounded)
    }

    private func applyCustomAudioDelay() {
        let trimmed = customAudioDelayInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let raw = Double(trimmed) else { return }
        let inSeconds: Double
        if audioUnit == .milliseconds || abs(raw) >= 50.0 {
            inSeconds = raw / 1000.0
        } else {
            inSeconds = raw
        }
        let rounded = (inSeconds * 100.0).rounded() / 100.0
        audioDelay = rounded
        customAudioDelayInput = String(format: "%.2f", rounded)
        mpv.setAudioDelay(rounded)
    }

    // MARK: - Section 4: Video Filters & Aspect Ratio

    private var videoView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Aspect Ratio Override
            VStack(alignment: .leading, spacing: 8) {
                Text("Aspect Ratio Override")
                    .font(.system(size: 14, weight: .bold))

                HStack(spacing: 8) {
                    aspectButton(label: "Auto", value: "auto")
                    aspectButton(label: "16:9", value: "16:9")
                    aspectButton(label: "21:9", value: "21:9")
                    aspectButton(label: "4:3", value: "4:3")
                }
            }

            Divider().background(Color.white.opacity(0.15))

            // Deband Shader
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deband Filter")
                        .font(.system(size: 14, weight: .bold))
                    Text("Smooths color banding artifacts in dark shadows and gradient skies")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { isDebandEnabled },
                    set: { newVal in
                        isDebandEnabled = newVal
                        mpv.toggleDeband()
                    }
                ))
                .toggleStyle(.switch)
                .tint(.cyan)
                .labelsHidden()
            }

            Divider().background(Color.white.opacity(0.15))

            // Color adjustments
            VStack(spacing: 12) {
                sliderAdjustment(label: "Contrast", value: $contrast) { val in
                    mpv.setContrast(val)
                }

                sliderAdjustment(label: "Brightness", value: $brightness) { val in
                    mpv.setBrightness(val)
                }

                sliderAdjustment(label: "Saturation", value: $saturation) { val in
                    mpv.setSaturation(val)
                }

                if contrast != 0 || brightness != 0 || saturation != 0 {
                    Button {
                        contrast = 0
                        brightness = 0
                        saturation = 0
                        mpv.setContrast(0)
                        mpv.setBrightness(0)
                        mpv.setSaturation(0)
                    } label: {
                        Text("Reset Color Filters")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.cyan)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color.cyan.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func aspectButton(label: String, value: String) -> some View {
        let isSelected = videoAspect == value
        return Button {
            videoAspect = value
            mpv.setVideoAspect(value)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.8))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.cyan.opacity(0.35) : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.cyan : Color.white.opacity(0.15), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sliderAdjustment(label: String, value: Binding<Double>, onCommit: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(String(format: "%+.0f", value.wrappedValue))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
            }
            Slider(
                value: Binding(
                    get: { value.wrappedValue },
                    set: { newVal in
                        let rounded = newVal.rounded()
                        if value.wrappedValue != rounded {
                            value.wrappedValue = rounded
                            onCommit(rounded)
                        }
                    }
                ),
                in: -50...50,
                step: 1.0
            )
            .tint(.cyan)
        }
    }

    private func calibrationButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
