import SwiftUI

/// Modal sheet for editing or setting the user's account display name.
struct EditDisplayNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var authManager = AuthManager.shared
    @ObservedObject private var languageManager = LanguageManager.shared
    @State private var nameDraft: String = ""
    @State private var isSaving: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 38))
                    .foregroundStyle(.blue.gradient)
                    .padding(.bottom, 2)

                Text("Display Name".localized)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)

                Text("Choose how your name appears across profiles and library sync.".localized)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }

            // Input Field
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "person.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    TextField("Enter your name…".localized, text: $nameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isFocused)
                        .onSubmit { saveName() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(isFocused ? 0.25 : 0.1), lineWidth: 1)
                )
            }

            // Action Buttons
            HStack(spacing: 12) {
                Button("Cancel".localized) {
                    authManager.markDisplayNameAsCustomized()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)

                Button(action: saveName) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 12)
                    } else {
                        Text("Save Name".localized)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 8)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 360)
        .background(Color(red: 0.11, green: 0.12, blue: 0.15))
        .preferredColorScheme(.dark)
        .onAppear {
            let current = authManager.currentUser?.displayName ?? ""
            let emailPrefix = authManager.currentUser?.email?.components(separatedBy: "@").first ?? ""
            nameDraft = (current == emailPrefix && !current.isEmpty) ? "" : current
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }

    private func saveName() {
        let clean = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        isSaving = true
        authManager.updateDisplayName(clean)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isSaving = false
            dismiss()
        }
    }
}
