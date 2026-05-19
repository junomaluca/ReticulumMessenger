// SPDX-License-Identifier: MIT
// ReticulumMessenger — PeerInfo.swift

import Foundation
import LXMFKit

/// UI-friendly representation of a known network peer.
struct PeerInfo: Identifiable {
    let destinationHash: Data
    let displayName: String
    let hexHash: String
    let shortHash: String
    let lastSeen: Date

    var id: Data { destinationHash }

    init(from peer: LXMPeer) {
        self.destinationHash = peer.destinationHash
        self.displayName = peer.displayName
        self.hexHash = peer.hexHash
        self.shortHash = peer.shortHash
        self.lastSeen = peer.lastSeen
    }

    init(destinationHash: Data, displayName: String, lastSeen: Date = Date()) {
        self.destinationHash = destinationHash
        self.displayName = displayName
        self.hexHash = destinationHash.map { String(format: "%02x", $0) }.joined()
        self.shortHash = String(hexHash.prefix(12))
        self.lastSeen = lastSeen
    }
}
