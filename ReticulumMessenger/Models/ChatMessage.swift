// SPDX-License-Identifier: MIT
// ReticulumMessenger — ChatMessage.swift

import Foundation
import LXMFKit

/// Emoji reaction on a message.
struct MessageReaction: Codable, Equatable {
    let emoji: String
    let isLocal: Bool
    let timestamp: Date

    init(emoji: String, isLocal: Bool) {
        self.emoji = emoji
        self.isLocal = isLocal
        self.timestamp = Date()
    }
}

/// A single chat message within a conversation.
struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let lxmfId: Data
    let content: String
    let timestamp: Date
    let isIncoming: Bool
    var state: MessageState
    var isRead: Bool
    var reactions: [MessageReaction]
    var expiresAt: Date?

    enum MessageState: String, Codable {
        case pending
        case sent
        case delivered
        case failed
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    init(
        lxmfId: Data = Data(),
        content: String,
        timestamp: Date = Date(),
        isIncoming: Bool,
        state: MessageState = .pending,
        isRead: Bool = false,
        reactions: [MessageReaction] = [],
        expiresAt: Date? = nil
    ) {
        self.id = UUID()
        self.lxmfId = lxmfId
        self.content = content
        self.timestamp = timestamp
        self.isIncoming = isIncoming
        self.state = state
        self.isRead = isRead
        self.reactions = reactions
        self.expiresAt = expiresAt
    }

    /// Create from an LXMF message.
    init(from lxMessage: LXMessage) {
        self.id = UUID()
        self.lxmfId = lxMessage.id
        self.content = lxMessage.content
        self.timestamp = lxMessage.timestamp
        self.isIncoming = lxMessage.isIncoming

        switch lxMessage.state {
        case .sent: self.state = .sent
        case .delivered, .received: self.state = .delivered
        case .failed: self.state = .failed
        default: self.state = .pending
        }

        self.isRead = !lxMessage.isIncoming
        self.reactions = []
        self.expiresAt = nil
    }

    // Custom decoder for backward compatibility with older saved data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        lxmfId = try container.decode(Data.self, forKey: .lxmfId)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isIncoming = try container.decode(Bool.self, forKey: .isIncoming)
        state = try container.decode(MessageState.self, forKey: .state)
        isRead = try container.decode(Bool.self, forKey: .isRead)
        reactions = try container.decodeIfPresent([MessageReaction].self, forKey: .reactions) ?? []
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, lxmfId, content, timestamp, isIncoming, state, isRead, reactions, expiresAt
    }

    mutating func toggleReaction(_ emoji: String, isLocal: Bool) {
        if let idx = reactions.firstIndex(where: { $0.emoji == emoji && $0.isLocal == isLocal }) {
            reactions.remove(at: idx)
        } else {
            reactions.append(MessageReaction(emoji: emoji, isLocal: isLocal))
        }
    }
}
