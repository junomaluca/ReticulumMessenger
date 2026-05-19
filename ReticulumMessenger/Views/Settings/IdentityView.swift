// SPDX-License-Identifier: MIT
// ReticulumMessenger — IdentityView.swift

import SwiftUI

struct IdentityView: View {
    @EnvironmentObject var appState: AppState
    @State private var identityCopied = false
    @State private var deliveryCopied = false

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 16) {
                        AvatarView(
                            hash: Data(hexString: appState.localIdentityHash) ?? Data(),
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
                        identityCopied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            identityCopied = false
                        }
                    } label: {
                        Label(
                            identityCopied ? "Copied!" : "Copy to Clipboard",
                            systemImage: identityCopied ? "checkmark" : "doc.on.doc"
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
                        deliveryCopied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            deliveryCopied = false
                        }
                    } label: {
                        Label(
                            deliveryCopied ? "Copied!" : "Copy to Clipboard",
                            systemImage: deliveryCopied ? "checkmark" : "doc.on.doc"
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

}
