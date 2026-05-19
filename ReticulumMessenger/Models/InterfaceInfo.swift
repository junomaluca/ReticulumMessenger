// SPDX-License-Identifier: MIT
// ReticulumMessenger — InterfaceInfo.swift

import Foundation
import ReticulumKit

/// UI-friendly representation of a network interface.
struct InterfaceInfo: Identifiable {
    let name: String
    let type: String
    let isOnline: Bool
    let bytesSent: UInt64
    let bytesReceived: UInt64
    let statusText: String

    var id: String { name }

    init(from interface: any RNSInterface) {
        self.name = interface.name
        self.type = interface.interfaceType
        self.isOnline = interface.isOnline
        self.bytesSent = interface.bytesSent
        self.bytesReceived = interface.bytesReceived

        switch interface.status {
        case .connected: self.statusText = "Connected"
        case .connecting: self.statusText = "Connecting"
        case .disconnected: self.statusText = "Disconnected"
        case .error(let msg): self.statusText = "Error: \(msg)"
        }
    }

    /// Format bytes as human-readable string.
    static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
