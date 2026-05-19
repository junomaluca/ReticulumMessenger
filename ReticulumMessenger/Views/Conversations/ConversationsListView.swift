// SPDX-License-Identifier: MIT
// ReticulumMessenger — ConversationsListView.swift

import SwiftUI

struct ConversationsListView: View {
    @EnvironmentObject var appState: AppState
    @State private var showNewConversation = false
    @State private var showQRCode = false
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if appState.conversations.isEmpty {
                    emptyState
                } else {
                    conversationList
                }
            }
            .navigationTitle("Messages")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    StatusIndicator(status: appState.networkStatus)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showQRCode = true
                    } label: {
                        Image(systemName: "qrcode")
                    }

                    Button {
                        showNewConversation = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showNewConversation) {
                NewConversationView()
            }
            .sheet(isPresented: $showQRCode) {
                NavigationStack {
                    QRCodeView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showQRCode = false }
                            }
                        }
                }
            }
            .searchable(text: $searchText, prompt: "Search conversations")
        }
    }

    private var conversationList: some View {
        List {
            // Pinned section
            if !pinnedConversations.isEmpty {
                Section {
                    ForEach(pinnedConversations) { conversation in
                        NavigationLink(value: conversation) {
                            ConversationRow(conversation: conversation)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                appState.togglePin(conversation.id)
                            } label: {
                                Label("Unpin", systemImage: "pin.slash")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteConversation(conversation.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Label("Pinned", systemImage: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Regular conversations
            Section {
                ForEach(unpinnedConversations) { conversation in
                    NavigationLink(value: conversation) {
                        ConversationRow(conversation: conversation)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            appState.togglePin(conversation.id)
                        } label: {
                            Label("Pin", systemImage: "pin")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteConversation(conversation.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: Conversation.self) { conversation in
            MessageView(conversation: conversation)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Start a new conversation by tapping the compose button, or wait for incoming messages from the mesh network.")
        } actions: {
            Button("New Conversation") {
                showNewConversation = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var filteredConversations: [Conversation] {
        let active = appState.conversations.filter { !$0.isArchived }
        if searchText.isEmpty { return active }
        return active.filter {
            $0.resolvedName.localizedCaseInsensitiveContains(searchText) ||
            $0.peerHexHash.contains(searchText.lowercased())
        }
    }

    private var pinnedConversations: [Conversation] {
        filteredConversations.filter { $0.isPinned }
    }

    private var unpinnedConversations: [Conversation] {
        filteredConversations.filter { !$0.isPinned }
    }

    private func deleteConversation(_ id: UUID) {
        appState.conversations.removeAll { $0.id == id }
        appState.storageService?.saveConversations(appState.conversations)
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(hash: conversation.peerHash, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if conversation.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Text(conversation.resolvedName)
                        .font(.headline)
                        .lineLimit(1)

                    if conversation.disappearingDuration != .off {
                        Image(systemName: "timer")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    if let lastMsg = conversation.lastMessage {
                        Text(lastMsg.timestamp, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    if let lastMsg = conversation.lastMessage {
                        if !lastMsg.isIncoming {
                            Image(systemName: messageStateIcon(lastMsg.state))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(lastMsg.content)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("No messages yet")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func messageStateIcon(_ state: ChatMessage.MessageState) -> String {
        switch state {
        case .pending: return "clock"
        case .sent: return "checkmark"
        case .delivered: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}
