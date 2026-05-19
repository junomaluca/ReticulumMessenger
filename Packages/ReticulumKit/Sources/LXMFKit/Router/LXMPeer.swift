// SPDX-License-Identifier: MIT
// LXMFKit — LXMPeer.swift
// Represents a known LXMF peer on the network.

import Foundation
import ReticulumKit

/// A known LXMF peer discovered via announce or direct communication.
public struct LXMPeer: Identifiable, Sendable {

    // MARK: - Properties

    /// The peer's LXMF delivery destination hash.
    public let destinationHash: Data

    /// The peer's Reticulum identity.
    public let identity: RNSIdentity

    /// Application data from the peer's announce (may contain display name, etc.).
    public let appData: Data?

    /// When this peer was last seen.
    public var lastSeen: Date

    /// Display name extracted from app data or identity hash.
    public var displayName: String {
        // Try to extract name from app data
        if let data = appData, let name = String(data: data, encoding: .utf8), !name.isEmpty {
            return name
        }
        // Fall back to short hash
        return shortHash
    }

    /// Hex string of the destination hash.
    public var hexHash: String {
        destinationHash.map { String(format: "%02x", $0) }.joined()
    }

    /// Short hash for display (first 12 characters).
    public var shortHash: String {
        String(hexHash.prefix(12))
    }

    /// Conformance to Identifiable.
    public var id: Data { destinationHash }

    // MARK: - Initialization

    public init(
        destinationHash: Data,
        identity: RNSIdentity,
        appData: Data? = nil,
        lastSeen: Date = Date()
    ) {
        self.destinationHash = destinationHash
        self.identity = identity
        self.appData = appData
        self.lastSeen = lastSeen
    }
}

extension LXMPeer: Equatable {
    public static func == (lhs: LXMPeer, rhs: LXMPeer) -> Bool {
        lhs.destinationHash == rhs.destinationHash
    }
}

extension LXMPeer: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(destinationHash)
    }
}
