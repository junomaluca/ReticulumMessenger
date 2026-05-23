// SPDX-License-Identifier: MIT
// ReticulumMessenger — SelfTestView.swift

import SwiftUI

struct SelfTestView: View {
    @EnvironmentObject var appState: AppState
    @State private var targetHex: String = ""

    var body: some View {
        List {
            Section {
                TextField("Target LXMF address (32 hex chars)", text: $targetHex)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !recentPeers.isEmpty {
                    ForEach(recentPeers, id: \.hash) { peer in
                        Button {
                            targetHex = peer.hash
                        } label: {
                            HStack {
                                Image(systemName: "person.circle")
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.name)
                                        .font(.caption)
                                    Text(peer.hash)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if targetHex == peer.hash {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }

                Button {
                    Task {
                        await appState.runOutboundSelfTest(targetHex: targetHex.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                } label: {
                    HStack {
                        Label("Run Self-Test", systemImage: "play.fill")
                        if appState.selfTestRunning {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(targetHex.trimmingCharacters(in: .whitespacesAndNewlines).count != 32 || appState.selfTestRunning)
            } header: {
                Text("Outbound Attachment Test")
            } footer: {
                Text("Sends 8 test messages (text, JPEG, PNG, audio, text file, PDF, 50KB binary, captioned image) to the target address.")
            }

            if !appState.selfTestResults.isEmpty {
                Section("Results") {
                    ForEach(Array(appState.selfTestResults.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 8) {
                            if line.hasPrefix("PASS") {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            } else if line.hasPrefix("FAIL") {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.caption)
                            } else if line.hasPrefix("Done") {
                                Image(systemName: "flag.checkered")
                                    .font(.caption)
                            } else {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }

            Section("Attachment Stats") {
                LabeledContent("Received") {
                    Text("\(appState.attachmentStats.totalReceived)")
                        .monospaced()
                }
                LabeledContent("Sent") {
                    Text("\(appState.attachmentStats.totalSent)")
                        .monospaced()
                }
                LabeledContent("Failed") {
                    Text("\(appState.attachmentStats.totalFailed)")
                        .monospaced()
                        .foregroundColor(appState.attachmentStats.totalFailed > 0 ? .red : .primary)
                }
                if !appState.attachmentStats.receivedByType.isEmpty {
                    LabeledContent("By type") {
                        Text(appState.attachmentStats.receivedByType
                            .sorted(by: { $0.key < $1.key })
                            .map { "\($0.key): \($0.value)" }
                            .joined(separator: ", "))
                            .font(.caption)
                            .monospaced()
                    }
                }
            }
        }
        .navigationTitle("Self-Test")
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct PeerEntry {
        let name: String
        let hash: String
    }

    private var recentPeers: [PeerEntry] {
        var peers: [PeerEntry] = []
        let seen = Set<String>()
        for peer in appState.knownPeers.prefix(5) {
            let hash = peer.destinationHash.map { String(format: "%02x", $0) }.joined()
            if hash.count == 32 && !seen.contains(hash) {
                peers.append(PeerEntry(name: peer.displayName, hash: hash))
            }
        }
        for conv in appState.conversations.prefix(5) where !conv.isGroup {
            let hash = conv.peerHexHash
            if hash.count == 32 && !peers.contains(where: { $0.hash == hash }) {
                peers.append(PeerEntry(name: conv.resolvedName, hash: hash))
            }
        }
        return peers
    }
}
