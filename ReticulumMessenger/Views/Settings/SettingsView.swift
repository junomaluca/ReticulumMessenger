// SPDX-License-Identifier: MIT
// ReticulumMessenger — SettingsView.swift

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var displayName: String = ""
    @State private var showResetConfirm = false

    var body: some View {
        NavigationStack {
            List {
                // Profile
                Section("Profile") {
                    HStack {
                        if !appState.localIdentityHash.isEmpty {
                            AvatarView(
                                hash: hexToData(appState.localIdentityHash) ?? Data(),
                                size: 56
                            )
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Display Name", text: $displayName)
                                .font(.headline)
                                .onSubmit { saveDisplayName() }
                            Text(appState.localIdentityHash.isEmpty ? "..." : String(appState.localIdentityHash.prefix(16)))
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Identity
                Section("Identity") {
                    NavigationLink("Identity Details") {
                        IdentityView()
                    }

                    Button("Announce on Network") {
                        Task {
                            try? await appState.messengerService?.announce(
                                displayName: displayName.isEmpty ? nil : displayName
                            )
                        }
                    }
                }

                // Network
                Section("Network") {
                    NavigationLink("Manage Interfaces") {
                        InterfacesView()
                    }
                }

                // About
                Section("About") {
                    LabeledContent("Version", value: "0.1.0")
                    LabeledContent("Protocol", value: "Reticulum")
                    LabeledContent("Messaging", value: "LXMF")

                    NavigationLink("About Reticulum Messenger") {
                        AboutView()
                    }
                }

                // Danger Zone
                Section {
                    Button("Reset Identity", role: .destructive) {
                        showResetConfirm = true
                    }
                } footer: {
                    Text("Resetting your identity will generate new cryptographic keys. You will no longer be reachable at your current address.")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                displayName = appState.storageService?.loadDisplayName() ?? ""
            }
            .confirmationDialog(
                "Reset Identity?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    // Would reset identity
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will generate a new identity. Your current address will become unreachable. This cannot be undone.")
            }
        }
    }

    private func saveDisplayName() {
        appState.storageService?.saveDisplayName(displayName.isEmpty ? nil : displayName)
    }

    private func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard nextIndex != index else { return nil }
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}
