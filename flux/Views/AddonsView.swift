import SwiftUI

struct AddonsView: View {
    @ObservedObject var addonManager = AddonManager.shared
    @State private var newAddonUrl = ""
    @State private var isAdding = false
    @State private var addError: String?
    
    var body: some View {
        Form {
            Section(header: Text("Add Stremio Addon")) {
                TextField("Addon URL (e.g. https://domain.com/manifest.json)", text: $newAddonUrl)
                
                Button(action: {
                    addAddon()
                }) {
                    if isAdding {
                        ProgressView().progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Text("Add")
                    }
                }
                .disabled(newAddonUrl.isEmpty || isAdding)
                
                if let error = addError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            
            Section(header: Text("Installed Addons")) {
                if addonManager.addons.isEmpty {
                    Text("No addons installed.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(addonManager.addons) { addon in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(addon.name).font(.headline)
                                if let desc = addon.description {
                                    Text(desc).font(.caption).foregroundStyle(.secondary)
                                }
                                if let version = addon.version {
                                    Text("v\(version)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { addon.isEnabled },
                                set: { _ in addonManager.toggleAddon(addon) }
                            ))
                            .labelsHidden()
                            
                            if !addon.url.isEmpty {
                                Button(action: {
                                    if let configureURL = URL(string: addon.url) {
                                        NSWorkspace.shared.open(configureURL)
                                    }
                                }) {
                                    Image(systemName: "gearshape")
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.borderless)
                            }
                            
                            Button(action: {
                                addonManager.removeAddon(addon)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
    
    private func addAddon() {
        guard !newAddonUrl.isEmpty else { return }
        isAdding = true
        addError = nil
        let urlObj = newAddonUrl // capture
        Task {
            do {
                try await addonManager.addAddon(url: urlObj)
                await MainActor.run {
                    self.newAddonUrl = ""
                    self.isAdding = false
                }
            } catch {
                await MainActor.run {
                    self.addError = "Failed to load addon: \(error.localizedDescription)"
                    self.isAdding = false
                }
            }
        }
    }
}
