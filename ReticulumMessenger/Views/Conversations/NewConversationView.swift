// SPDX-License-Identifier: MIT
// ReticulumMessenger — NewConversationView.swift

import SwiftUI

struct NewConversationView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var destinationHash = ""
    @State private var displayName = ""
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Destination Hash", text: $destinationHash)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))

                    TextField("Display Name (optional)", text: $displayName)
                } header: {
                    Text("New Conversation")
                } footer: {
                    Text("Enter the LXMF destination hash of the peer you want to message. This is a 32-character hex string.")
                }

                if !appState.knownPeers.isEmpty {
                    Section("Discovered Peers") {
                        ForEach(appState.knownPeers) { peer in
                            Button {
                                destinationHash = peer.hexHash
                                displayName = peer.displayName
                            } label: {
                                HStack {
                                    AvatarView(hash: peer.destinationHash, size: 36)
                                    VStack(alignment: .leading) {
                                        Text(peer.displayName)
                                            .font(.body)
                                        Text(peer.shortHash)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .monospaced()
                                    }
                                    Spacer()
                                    Text(peer.lastSeen, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createConversation() }
                        .disabled(!isValid)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var isValid: Bool {
        let cleaned = destinationHash.replacingOccurrences(of: " ", with: "")
        return cleaned.count == 32 && cleaned.allSatisfy { $0.isHexDigit }
    }

    private func createConversation() {
        let cleaned = destinationHash.replacingOccurrences(of: " ", with: "").lowercased()
        guard let hashData = hexToData(cleaned) else {
            errorMessage = "Invalid hex string"
            showError = true
            return
        }

        let name = displayName.isEmpty ? nil : displayName
        appState.createConversation(with: hashData, name: name)
        dismiss()
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
