// SPDX-License-Identifier: MIT
// ReticulumMessenger — Conversation.swift

import Foundation

/// Duration after which messages auto-delete.
enum DisappearingDuration: String, Codable, CaseIterable {
    case off = "off"
    case thirtySeconds = "30s"
    case fiveMinutes = "5m"
    case oneHour = "1h"
    case twentyFourHours = "24h"
    case oneWeek = "7d"

    var label: String {
        switch self {
        case .off: return String(localized: "Off")
        case .thirtySeconds: return String(localized: "30 seconds")
        case .fiveMinutes: return String(localized: "5 minutes")
        case .oneHour: return String(localized: "1 hour")
        case .twentyFourHours: return String(localized: "24 hours")
        case .oneWeek: return String(localized: "1 week")
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .thirtySeconds: return 30
        case .fiveMinutes: return 300
        case .oneHour: return 3600
        case .twentyFourHours: return 86400
        case .oneWeek: return 604800
        }
    }

    var icon: String {
        switch self {
        case .off: return "timer"
        case .thirtySeconds: return "30.circle"
        case .fiveMinutes: return "5.circle"
        case .oneHour: return "clock"
        case .twentyFourHours: return "clock.badge.checkmark"
        case .oneWeek: return "calendar.circle"
        }
    }
}

/// A conversation with a specific peer or group, containing message history.
struct Conversation: Identifiable, Codable, Hashable {
    // Hash by id only (cheap & stable for NavigationPath / Set use).
    // Equatable is synthesized over all stored properties so SwiftUI
    // re-renders rows when messages, displayName, etc. change.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    let id: UUID
    let peerHash: Data
    var displayName: String?
    var messages: [ChatMessage]
    var lastActivity: Date
    var isArchived: Bool
    var isPinned: Bool
    var disappearingDuration: DisappearingDuration

    // Group conversation support
    var isGroup: Bool
    var groupId: Data?
    var memberHashes: [Data]

    var peerHexHash: String {
        peerHash.map { String(format: "%02x", $0) }.joined()
    }

    var groupHexId: String? {
        groupId?.map { String(format: "%02x", $0) }.joined()
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
        isArchived: Bool = false,
        isPinned: Bool = false,
        disappearingDuration: DisappearingDuration = .off,
        isGroup: Bool = false,
        groupId: Data? = nil,
        memberHashes: [Data] = []
    ) {
        self.id = UUID()
        self.peerHash = peerHash
        self.displayName = displayName
        self.messages = messages
        self.lastActivity = lastActivity
        self.isArchived = isArchived
        self.isPinned = isPinned
        self.disappearingDuration = disappearingDuration
        self.isGroup = isGroup
        self.groupId = groupId
        self.memberHashes = memberHashes
    }

    // Custom decoder for backward compatibility with older saved data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        peerHash = try container.decode(Data.self, forKey: .peerHash)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        lastActivity = try container.decode(Date.self, forKey: .lastActivity)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        disappearingDuration = try container.decodeIfPresent(DisappearingDuration.self, forKey: .disappearingDuration) ?? .off
        isGroup = try container.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        groupId = try container.decodeIfPresent(Data.self, forKey: .groupId)
        memberHashes = try container.decodeIfPresent([Data].self, forKey: .memberHashes) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, peerHash, displayName, messages, lastActivity, isArchived, isPinned, disappearingDuration
        case isGroup, groupId, memberHashes
    }

    /// The name to display — either the set display name or the short hash.
    var resolvedName: String {
        displayName ?? shortHash
    }
}
