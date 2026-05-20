// SPDX-License-Identifier: MIT
// ReticulumMessenger — GroupDetailView.swift

import SwiftUI

struct GroupDetailView: View {
    @EnvironmentObject var appState: AppState
    let conversation: Conversation

    @State private var disappearingDuration: DisappearingDuration = .off

    private var currentConversation: Conversation {
        appState.conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.15))
                                .frame(width: 80, height: 80)
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(conversation.resolvedName)
                            .font(.title2.bold())
                        Text("\(currentConversation.memberHashes.count) members")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section("Members") {
                ForEach(currentConversation.memberHashes, id: \.self) { memberHash in
                    HStack {
                        AvatarView(hash: memberHash, size: 36)
                        VStack(alignment: .leading) {
                            Text(peerName(for: memberHash))
                                .font(.body)
                            Text(memberHash.map { String(format: "%02x", $0) }.joined().prefix(12) + "...")
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Details") {
                LabeledContent("Messages") {
                    Text("\(currentConversation.messages.count)")
                }
                if let groupHex = currentConversation.groupHexId {
                    LabeledContent("Group ID") {
                        Text(String(groupHex.prefix(16)) + "...")
                            .monospaced()
                            .font(.caption)
                    }
                }
            }

            Section {
                Picker("Auto-delete after", selection: $disappearingDuration) {
                    ForEach(DisappearingDuration.allCases, id: \.self) { duration in
                        Label(duration.label, systemImage: duration.icon)
                            .tag(duration)
                    }
                }
                .onChange(of: disappearingDuration) { _, newValue in
                    appState.setDisappearingDuration(newValue, for: conversation.id)
                }
            } header: {
                Text("Disappearing Messages")
            }
        }
        .navigationTitle("Group Info")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let conv = appState.conversations.first(where: { $0.id == conversation.id }) {
                disappearingDuration = conv.disappearingDuration
            }
        }
    }

    private func peerName(for hash: Data) -> String {
        if let peer = appState.knownPeers.first(where: { $0.destinationHash == hash }) {
            return peer.displayName
        }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }
}
