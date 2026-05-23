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

/// Attachment metadata stored with a chat message.
/// Large attachments (>8KB) are stored as external files to avoid bloating conversations.json.
struct ChatAttachment: Codable, Equatable {
    let filename: String
    let mimeType: String
    let data: Data

    private var externalRef: String?

    static let externalThreshold = 8_192

    private static var attachmentsDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ReticulumMessenger/attachments", isDirectory: true)
    }

    init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filename, forKey: .filename)
        try container.encode(mimeType, forKey: .mimeType)

        if data.count > Self.externalThreshold {
            let ref = externalRef ?? UUID().uuidString
            let dir = Self.attachmentsDir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent(ref)
            try? data.write(to: fileURL, options: .atomic)
            try container.encode(ref, forKey: .externalRef)
            try container.encode(Data(), forKey: .data)
        } else {
            try container.encode(data, forKey: .data)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = try container.decode(String.self, forKey: .filename)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        externalRef = try container.decodeIfPresent(String.self, forKey: .externalRef)

        let inlineData = try container.decode(Data.self, forKey: .data)
        if let ref = externalRef, inlineData.isEmpty {
            let fileURL = Self.attachmentsDir.appendingPathComponent(ref)
            data = (try? Data(contentsOf: fileURL)) ?? Data()
        } else {
            data = inlineData
        }
    }

    private enum CodingKeys: String, CodingKey {
        case filename, mimeType, data, externalRef
    }

    static func == (lhs: ChatAttachment, rhs: ChatAttachment) -> Bool {
        lhs.filename == rhs.filename && lhs.mimeType == rhs.mimeType && lhs.data == rhs.data
    }
}

/// A single chat message within a conversation.
struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let lxmfId: Data
    let content: String
    let timestamp: Date
    let isIncoming: Bool
    var state: MessageState
    var isRead: Bool
    var reactions: [MessageReaction]
    var expiresAt: Date?
    var senderName: String?
    var attachment: ChatAttachment?
    var extraAttachments: [ChatAttachment]?

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
        expiresAt: Date? = nil,
        senderName: String? = nil,
        attachment: ChatAttachment? = nil,
        extraAttachments: [ChatAttachment]? = nil
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
        self.senderName = senderName
        self.attachment = attachment
        self.extraAttachments = extraAttachments
    }

    var allAttachments: [ChatAttachment] {
        var result: [ChatAttachment] = []
        if let a = attachment { result.append(a) }
        if let extra = extraAttachments { result.append(contentsOf: extra) }
        return result
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
        self.senderName = lxMessage.sourceName

        // Capture all attachments
        if let first = lxMessage.attachments.first {
            self.attachment = ChatAttachment(
                filename: first.name,
                mimeType: first.mimeType,
                data: first.data
            )
            if lxMessage.attachments.count > 1 {
                self.extraAttachments = lxMessage.attachments.dropFirst().map {
                    ChatAttachment(filename: $0.name, mimeType: $0.mimeType, data: $0.data)
                }
            }
        } else {
            self.attachment = nil
        }
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
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName)
        attachment = try container.decodeIfPresent(ChatAttachment.self, forKey: .attachment)
        extraAttachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .extraAttachments)
    }

    private enum CodingKeys: String, CodingKey {
        case id, lxmfId, content, timestamp, isIncoming, state, isRead, reactions, expiresAt, senderName, attachment, extraAttachments
    }

    mutating func toggleReaction(_ emoji: String, isLocal: Bool) {
        if let idx = reactions.firstIndex(where: { $0.emoji == emoji && $0.isLocal == isLocal }) {
            reactions.remove(at: idx)
        } else {
            reactions.append(MessageReaction(emoji: emoji, isLocal: isLocal))
        }
    }
}

// MARK: - Attachment Statistics

struct AttachmentEvent {
    let timestamp: Date
    let direction: String    // "in" or "out"
    let mimeType: String
    let size: Int
    let filename: String
    let success: Bool
    let note: String?
}

struct AttachmentStats {
    var events: [AttachmentEvent] = []
    private let maxEvents = 50

    var totalReceived: Int { events.filter { $0.direction == "in" }.count }
    var totalSent: Int { events.filter { $0.direction == "out" }.count }
    var totalFailed: Int { events.filter { !$0.success }.count }

    var receivedByType: [String: Int] {
        var counts: [String: Int] = [:]
        for e in events where e.direction == "in" && e.success {
            let cat = Self.category(for: e.mimeType)
            counts[cat, default: 0] += 1
        }
        return counts
    }

    var totalBytesReceived: Int {
        events.filter { $0.direction == "in" && $0.success }.reduce(0) { $0 + $1.size }
    }

    var totalBytesSent: Int {
        events.filter { $0.direction == "out" && $0.success }.reduce(0) { $0 + $1.size }
    }

    mutating func record(_ event: AttachmentEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst()
        }
    }

    static func category(for mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "image" }
        if mimeType.hasPrefix("audio/") { return "audio" }
        if mimeType.contains("pdf") { return "pdf" }
        if mimeType.contains("text") || mimeType.contains("json") { return "text" }
        return "file"
    }
}
