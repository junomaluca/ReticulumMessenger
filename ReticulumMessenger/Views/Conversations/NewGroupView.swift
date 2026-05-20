// SPDX-License-Identifier: MIT
// ReticulumMessenger — NewGroupView.swift

import SwiftUI

struct NewGroupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    var onCreated: ((Conversation) -> Void)?

    @State private var groupName = ""
    @State private var selectedPeers: Set<String> = [] // hex hashes

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Group Name", text: $groupName)
                } header: {
                    Text("Group Info")
                } footer: {
                    Text("Choose a name for this group conversation.")
                }

                Section {
                    if appState.knownPeers.isEmpty {
                        Text("No peers discovered yet. Peers must announce on the network before they can be added to a group.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(appState.knownPeers) { peer in
                            Button {
                                togglePeer(peer.hexHash)
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
                                    if selectedPeers.contains(peer.hexHash) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.accentColor)
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                    }
                } header: {
                    HStack {
                        Text("Members")
                        Spacer()
                        Text("\(selectedPeers.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createGroup() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        !groupName.trimmingCharacters(in: .whitespaces).isEmpty && selectedPeers.count >= 1
    }

    private func togglePeer(_ hexHash: String) {
        if selectedPeers.contains(hexHash) {
            selectedPeers.remove(hexHash)
        } else {
            selectedPeers.insert(hexHash)
        }
    }

    private func createGroup() {
        let members = appState.knownPeers.filter { selectedPeers.contains($0.hexHash) }
        appState.createGroupConversation(name: groupName, members: members)
        let createdConversation = appState.conversations.first(where: { $0.isGroup && $0.displayName == groupName })
        dismiss()
        if let conversation = createdConversation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                onCreated?(conversation)
            }
        }
    }
}
