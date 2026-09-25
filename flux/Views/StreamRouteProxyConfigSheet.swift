import SwiftUI

/// Configuration sheet for Stream Route Proxy middleware.
/// Allows setting the forward proxy endpoint (e.g. Tailscale Tinyproxy),
/// configuring targeted host keywords (e.g. 2peckle, febbox),
/// and performing a live connection latency test.
struct StreamRouteProxyConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var proxyManager = StreamRouteProxyManager.shared

    @State private var endpoint: String = ""
    @State private var hostsText: String = ""
    @State private var isTesting = false
    @State private var testResultText: String?
    @State private var testResultIsSuccess = false

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 12) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 24))
                    .foregroundStyle(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Stream Route Proxy".localized)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Bypass residential ISP peering bottlenecks for HTTP scrapers".localized)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                Button("Done".localized) {
                    saveChanges()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(Color(red: 0.12, green: 0.13, blue: 0.16))

            Divider()
                .overlay(Color.white.opacity(0.08))

            // Body Content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {

                    // Card 1: Master Enable Toggle
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Enable Stream Route Proxy".localized)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Route matching HTTP streams through the forward proxy".localized)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.55))
                            }

                            Spacer()

                            Toggle("", isOn: $proxyManager.isEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                    // Card 2: Proxy Endpoint
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Proxy Endpoint URL".localized)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white)

                        HStack(spacing: 8) {
                            TextField("", text: $endpoint, prompt: Text("http://100.x.y.z:8888").foregroundColor(.white.opacity(0.3)))
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.25))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                )

                            Button(action: runConnectionTest) {
                                HStack(spacing: 5) {
                                    if isTesting {
                                        ProgressView()
                                            .scaleEffect(0.6)
                                            .frame(width: 14, height: 14)
                                    } else {
                                        Image(systemName: "bolt.horizontal.fill")
                                    }
                                    Text("Test Ping".localized)
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .disabled(isTesting || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if let result = testResultText {
                            HStack(spacing: 6) {
                                Image(systemName: testResultIsSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(testResultIsSuccess ? .green : .red)
                                Text(result)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(testResultIsSuccess ? .green : .red)
                            }
                            .padding(.top, 2)
                        }

                        Text("Tailscale mesh IP or LAN forward proxy listening on HTTP (e.g. Tinyproxy).".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.top, 2)
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                    // Card 3: Target Hosts / Scope
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Target Hosts & Scraper Scope".localized)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white)

                        TextField("", text: $hostsText, prompt: Text("2peckle, peckle, febbox").foregroundColor(.white.opacity(0.3)))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )

                        Text("Comma-separated domain keywords to route through the proxy. Direct streams matching these tokens will use the proxy; all other network traffic routes normally.".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.top, 2)
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                    // Card 4: Strict Safety Guarantee
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.blue)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Bypass Firewall Active".localized)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(.white)
                            Text("Torrents (P2P), local streaming engine (127.0.0.1), TMDB metadata, Cinemeta catalogs, and account sync are NEVER routed through the proxy under any circumstances.".localized)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
                }
                .padding(20)
            }
        }
        .frame(width: 520, height: 500)
        .background(Color(red: 0.10, green: 0.11, blue: 0.14))
        .preferredColorScheme(.dark)
        .onAppear {
            endpoint = proxyManager.endpointURL
            hostsText = proxyManager.targetHosts.joined(separator: ", ")
        }
    }

    private func saveChanges() {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        proxyManager.endpointURL = trimmedEndpoint

        let parsedHosts = hostsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !parsedHosts.isEmpty {
            proxyManager.targetHosts = parsedHosts
        }

        ProfileManager.shared.saveCurrentProfileSettings()
        AuthManager.shared.scheduleAutoSync(delay: 0.1)
    }

    private func runConnectionTest() {
        saveChanges()
        isTesting = true
        testResultText = nil

        Task {
            let result = await proxyManager.testConnection()
            await MainActor.run {
                isTesting = false
                switch result {
                case .success(let ms):
                    testResultIsSuccess = true
                    testResultText = "Connected successfully (\(Int(ms))ms roundtrip latency)"
                case .failure(let error):
                    testResultIsSuccess = false
                    testResultText = "Connection failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
