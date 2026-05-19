// SPDX-License-Identifier: MIT
// ReticulumMessenger — IdentityView.swift

import SwiftUI

struct IdentityView: View {
    @EnvironmentObject var appState: AppState
    @State private var showCopied = false

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 16) {
                        AvatarView(
                            hash: hexToData(appState.localIdentityHash) ?? Data(),
                            size: 96
                        )
                        Text("Your Identity")
                            .font(.title2.bold())
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section("Identity Hash") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(appState.localIdentityHash)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = appState.localIdentityHash
                        showCopied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            showCopied = false
                        }
                    } label: {
                        Label(
                            showCopied ? "Copied!" : "Copy to Clipboard",
                            systemImage: showCopied ? "checkmark" : "doc.on.doc"
                        )
                    }
                }
            }

            Section("LXMF Delivery Address") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(appState.deliveryHash)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = appState.deliveryHash
                        showCopied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            showCopied = false
                        }
                    } label: {
                        Label(
                            showCopied ? "Copied!" : "Copy to Clipboard",
                            systemImage: showCopied ? "checkmark" : "doc.on.doc"
                        )
                    }
                }
            }

            Section {
                Text("Your identity is a unique cryptographic keypair that identifies you on the Reticulum network. Share your LXMF delivery address with others so they can send you messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Identity")
        .navigationBarTitleDisplayMode(.inline)
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
