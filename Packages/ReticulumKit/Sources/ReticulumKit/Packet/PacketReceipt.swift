// SPDX-License-Identifier: MIT
// ReticulumKit — PacketReceipt.swift
// Tracks delivery status of sent packets.

import Foundation

/// Tracks the delivery and proof status of a sent packet.
public final class RNSPacketReceipt: @unchecked Sendable {

    // MARK: - Types

    public enum Status: Sendable {
        case sent
        case delivered
        case failed
        case expired
    }

    // MARK: - Properties

    /// The hash of the tracked packet.
    public let packetHash: Data

    /// Destination hash the packet was sent to.
    public let destinationHash: Data

    /// Current delivery status.
    public private(set) var status: Status = .sent

    /// Timestamp when the packet was sent.
    public let sentAt: Date

    /// Timestamp when proof was received (if delivered).
    public private(set) var provedAt: Date?

    /// Timeout interval for this receipt.
    public let timeout: TimeInterval

    /// Callback invoked on status change.
    public var statusCallback: ((Status) -> Void)?

    // MARK: - Initialization

    public init(
        packetHash: Data,
        destinationHash: Data,
        timeout: TimeInterval = 30.0
    ) {
        self.packetHash = packetHash
        self.destinationHash = destinationHash
        self.sentAt = Date()
        self.timeout = timeout
    }

    // MARK: - Status Updates

    /// Mark the packet as delivered with proof.
    public func prove() {
        guard status == .sent else { return }
        status = .delivered
        provedAt = Date()
        statusCallback?(.delivered)
    }

    /// Mark the packet as failed.
    public func fail() {
        guard status == .sent else { return }
        status = .failed
        statusCallback?(.failed)
    }

    /// Check if the receipt has expired.
    public func checkTimeout() {
        guard status == .sent else { return }
        if Date().timeIntervalSince(sentAt) > timeout {
            status = .expired
            statusCallback?(.expired)
        }
    }

    /// Whether the receipt is still pending.
    public var isPending: Bool {
        status == .sent
    }
}
