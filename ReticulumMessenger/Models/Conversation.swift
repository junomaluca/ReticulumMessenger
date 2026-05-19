// SPDX-License-Identifier: MIT
// ReticulumMessenger — Conversation.swift

import Foundation

/// A conversation with a specific peer, containing message history.
struct Conversation: Identifiable, Codable, Hashable {
    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    let id: UUID
    let peerHash: Data
    var displayName: String?
    var messages: [ChatMessage]
    var lastActivity: Date
    var isArchived: Bool

    var peerHexHash: String {
        peerHash.map { String(format: "%02x", $0) }.joined()
    }

    var shortHash: String {
        String(peerHexHash.prefix(12))
    }

    var lastMessage: ChatMessage? {
        messages.last
    }

    var unreadCount: Int {
        messages.filter { $0.isIncoming && !$0.isRead }.count
    }

    init(
        peerHash: Data,
        displayName: String? = nil,
        messages: [ChatMessage] = [],
        lastActivity: Date = Date(),
        isArchived: Bool = false
    ) {
        self.id = UUID()
        self.peerHash = peerHash
        self.displayName = displayName
        self.messages = messages
        self.lastActivity = lastActivity
        self.isArchived = isArchived
    }

    /// The name to display — either the set display name or the short hash.
    var resolvedName: String {
        displayName ?? shortHash
    }
}
