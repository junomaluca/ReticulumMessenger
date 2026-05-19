// SPDX-License-Identifier: MIT
// ReticulumMessenger — ChatMessage.swift

import Foundation
import LXMFKit

/// A single chat message within a conversation.
struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let lxmfId: Data
    let content: String
    let timestamp: Date
    let isIncoming: Bool
    var state: MessageState
    var isRead: Bool

    enum MessageState: String, Codable {
        case pending
        case sent
        case delivered
        case failed
    }

    init(
        lxmfId: Data = Data(),
        content: String,
        timestamp: Date = Date(),
        isIncoming: Bool,
        state: MessageState = .pending,
        isRead: Bool = false
    ) {
        self.id = UUID()
        self.lxmfId = lxmfId
        self.content = content
        self.timestamp = timestamp
        self.isIncoming = isIncoming
        self.state = state
        self.isRead = isRead
    }

    /// Create from an LXMF message.
    init(from lxMessage: LXMessage) {
        self.id = UUID()
        self.lxmfId = lxMessage.id
        self.content = lxMessage.content
        self.timestamp = lxMessage.timestamp
        self.isIncoming = lxMessage.isIncoming

        switch lxMessage.state {
        case .sent, .delivered: self.state = .sent
        case .failed: self.state = .failed
        case .received: self.state = .delivered
        default: self.state = .pending
        }

        self.isRead = !lxMessage.isIncoming
    }
}
