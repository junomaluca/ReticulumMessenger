// SPDX-License-Identifier: MIT
// ReticulumMessenger — ConversationsListView.swift

import SwiftUI

struct ConversationsListView: View {
    @EnvironmentObject var appState: AppState
    @State private var showNewConversation = false
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
                ToolbarItem(placement: .topBarTrailing) {
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
            .searchable(text: $searchText, prompt: "Search conversations")
        }
    }

    private var conversationList: some View {
        List {
            ForEach(filteredConversations) { conversation in
                NavigationLink(value: conversation) {
                    ConversationRow(conversation: conversation)
                }
            }
            .onDelete(perform: deleteConversations)
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
        if searchText.isEmpty {
            return appState.conversations.filter { !$0.isArchived }
        }
        return appState.conversations.filter {
            !$0.isArchived && (
                $0.resolvedName.localizedCaseInsensitiveContains(searchText) ||
                $0.peerHexHash.contains(searchText.lowercased())
            )
        }
    }

    private func deleteConversations(at offsets: IndexSet) {
        appState.conversations.remove(atOffsets: offsets)
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
                    Text(conversation.resolvedName)
                        .font(.headline)
                        .lineLimit(1)
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
                        Text("No messages")
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
                            .background(.accentColor, in: Capsule())
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
