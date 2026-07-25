import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("Claude API") {
                SecureField("API key", text: $apiKey)
                    .textContentType(.password)
                HStack {
                    Button("Save") {
                        try? KeychainStore.writeAPIKey(
                            apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        saved = true
                    }
                    if saved {
                        Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
                Text(
                    """
                    Used only to summarize transcripts. Stored in your Keychain. \
                    Recording and transcription happen entirely on this Mac.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .onAppear { apiKey = KeychainStore.readAPIKey() ?? "" }
        .onChange(of: apiKey) { saved = false }
    }
}
