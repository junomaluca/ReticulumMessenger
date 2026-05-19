// SPDX-License-Identifier: MIT
// ReticulumMessenger — IdentityExportView.swift

import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

/// Export and import encrypted identity backups.
struct IdentityExportView: View {
    @EnvironmentObject var appState: AppState
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showExportSuccess = false
    @State private var showImportPicker = false
    @State private var showImportPassword = false
    @State private var importURL: URL?
    @State private var importPassword = ""
    @State private var errorMessage: String?
    @State private var showImportSuccess = false
    @State private var exportedFileURL: URL?

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "key.viewfinder")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.accentColor)
                    Text("Identity Backup")
                        .font(.title3.bold())
                    Text("Export your cryptographic identity as an encrypted file. Anyone with this file and the password can impersonate you on the network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            // Export
            Section {
                SecureField("Password", text: $password)
                    .textContentType(.newPassword)
                SecureField("Confirm Password", text: $confirmPassword)
                    .textContentType(.newPassword)

                Button {
                    exportIdentity()
                } label: {
                    Label("Export Encrypted Backup", systemImage: "square.and.arrow.up")
                }
                .disabled(password.isEmpty || password != confirmPassword || password.count < 6)
            } header: {
                Text("Export Identity")
            } footer: {
                Text("Minimum 6 characters. Use a strong, unique password.")
            }

            // Import
            Section {
                Button {
                    showImportPicker = true
                } label: {
                    Label("Import from File", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Import Identity")
            } footer: {
                Text("Import an identity backup (.rnid file) to restore your address on this device. This will replace your current identity.")
            }

            // Identity fingerprint
            Section("Current Identity") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fingerprint")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(identityFingerprint)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)

                    FingerprintGrid(hash: appState.localIdentityHash)
                        .frame(height: 60)
                }
            }
        }
        .navigationTitle("Identity Backup")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Export Successful", isPresented: $showExportSuccess) {
            Button("Share File") {
                guard let url = exportedFileURL else { return }
                let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    rootVC.present(activityVC, animated: true)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your encrypted identity backup has been saved. Keep this file and password safe.")
        }
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showImportPicker) {
            IdentityFilePickerView { url in
                importURL = url
                showImportPassword = true
            }
        }
        .alert("Import Successful", isPresented: $showImportSuccess) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Identity imported successfully. Please restart the app for changes to take effect.")
        }
        .alert("Enter Backup Password", isPresented: $showImportPassword) {
            SecureField("Password", text: $importPassword)
            Button("Import", role: .destructive) { importIdentity() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the password used when the backup was created. This will replace your current identity.")
        }
    }

    private var identityFingerprint: String {
        let hash = appState.localIdentityHash
        guard hash.count >= 32 else { return hash }
        // Format as groups of 4 for readability
        var result = ""
        for (i, char) in hash.prefix(32).enumerated() {
            if i > 0 && i % 4 == 0 { result += " " }
            result.append(char)
        }
        return result.uppercased()
    }

    private func exportIdentity() {
        guard let storage = appState.storageService else { return }

        do {
            let url = try storage.exportIdentity(password: password)
            exportedFileURL = url
            showExportSuccess = true
            password = ""
            confirmPassword = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importIdentity() {
        guard let url = importURL, let storage = appState.storageService else { return }

        do {
            try storage.importIdentity(from: url, password: importPassword)
            importPassword = ""
            importURL = nil
            showImportSuccess = true
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}

/// Visual fingerprint grid based on identity hash.
struct FingerprintGrid: View {
    let hash: String

    private var colors: [Color] {
        let palette: [Color] = [.red, .orange, .yellow, .green, .mint, .cyan, .blue, .indigo, .purple, .pink, .brown, .gray]
        return hash.prefix(24).map { char in
            let value = Int(String(char), radix: 16) ?? 0
            return palette[value % palette.count]
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.gradient)
            }
        }
    }
}

/// Document picker for .rnid identity files.
struct IdentityFilePickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
