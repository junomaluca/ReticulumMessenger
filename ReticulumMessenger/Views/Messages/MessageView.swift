// SPDX-License-Identifier: MIT
// ReticulumMessenger — MessageView.swift

import SwiftUI

struct MessageView: View {
    @EnvironmentObject var appState: AppState
    let conversation: Conversation

    @State private var messageText = ""
    @State private var isSending = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(currentMessages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .onChange(of: currentMessages.count) { _, _ in
                    if let last = currentMessages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let last = currentMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Input bar
            MessageInputView(
                text: $messageText,
                isSending: isSending,
                isFocused: $isInputFocused,
                onSend: sendMessage
            )
        }
        .navigationTitle(conversation.resolvedName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    PeerDetailView(conversation: conversation)
                } label: {
                    AvatarView(hash: conversation.peerHash, size: 28)
                }
            }
        }
        .onAppear {
            markAsRead()
        }
    }

    private var currentMessages: [ChatMessage] {
        appState.conversations.first(where: { $0.id == conversation.id })?.messages ?? conversation.messages
    }

    private func sendMessage() {
        let content = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        messageText = ""
        isSending = true

        Task {
            do {
                try await appState.sendMessage(content: content, to: conversation.peerHash)
            } catch {
                // Message will show as failed in the UI
            }
            isSending = false
        }
    }

    private func markAsRead() {
        guard let idx = appState.conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        for i in appState.conversations[idx].messages.indices {
            if appState.conversations[idx].messages[i].isIncoming {
                appState.conversations[idx].messages[i].isRead = true
            }
        }
    }
}

// MARK: - Peer Detail

struct PeerDetailView: View {
    let conversation: Conversation

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        AvatarView(hash: conversation.peerHash, size: 80)
                        Text(conversation.resolvedName)
                            .font(.title2.bold())
                        Text(conversation.peerHexHash)
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section("Details") {
                LabeledContent("Destination Hash") {
                    Text(conversation.shortHash)
                        .monospaced()
                }
                LabeledContent("Messages") {
                    Text("\(conversation.messages.count)")
                }
                if let lastMsg = conversation.lastMessage {
                    LabeledContent("Last Activity") {
                        Text(lastMsg.timestamp, style: .relative)
                    }
                }
            }
        }
        .navigationTitle("Peer Info")
        .navigationBarTitleDisplayMode(.inline)
    }
}
