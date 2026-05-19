// SPDX-License-Identifier: MIT
// ReticulumKit — Channel.swift
// Structured message channels over Reticulum links.

import Foundation

/// A structured message channel over a Reticulum link.
/// Channels provide ordered, typed message delivery with sequence numbers.
public final class RNSChannel: @unchecked Sendable {

    // MARK: - Types

    /// A channel message with type and sequence tracking.
    public struct Message: Sendable {
        public let type: UInt16
        public let data: Data
        public let sequence: UInt32

        public init(type: UInt16, data: Data, sequence: UInt32 = 0) {
            self.type = type
            self.data = data
            self.sequence = sequence
        }

        /// Serialize the message for transmission.
        public func serialize() -> Data {
            var result = Data()
            // Type: 2 bytes big-endian
            result.append(UInt8(type >> 8))
            result.append(UInt8(type & 0xFF))
            // Sequence: 4 bytes big-endian
            result.append(UInt8((sequence >> 24) & 0xFF))
            result.append(UInt8((sequence >> 16) & 0xFF))
            result.append(UInt8((sequence >> 8) & 0xFF))
            result.append(UInt8(sequence & 0xFF))
            // Data
            result.append(data)
            return result
        }

        /// Deserialize a message from received bytes.
        public static func deserialize(_ data: Data) -> Message? {
            guard data.count >= 6 else { return nil }
            let type = UInt16(data[0]) << 8 | UInt16(data[1])
            let seq = UInt32(data[2]) << 24 | UInt32(data[3]) << 16 |
                      UInt32(data[4]) << 8 | UInt32(data[5])
            let payload = data.count > 6 ? Data(data[6...]) : Data()
            return Message(type: type, data: payload, sequence: seq)
        }
    }

    // MARK: - Properties

    /// The link this channel operates on.
    private weak var link: RNSLink?

    /// Next outgoing sequence number.
    private var nextSequence: UInt32 = 0

    /// Callback for received channel messages.
    public var messageCallback: ((Message) -> Void)?

    /// Registered message type handlers.
    private var handlers: [UInt16: (Message) -> Void] = [:]

    // MARK: - Initialization

    init(link: RNSLink) {
        self.link = link
    }

    // MARK: - Sending

    /// Send a typed message on this channel.
    @discardableResult
    public func send(type: UInt16, data: Data) throws -> UInt32 {
        guard let link = link else {
            throw RNSChannelError.noLink
        }

        let seq = nextSequence
        nextSequence += 1

        let message = Message(type: type, data: data, sequence: seq)
        let serialized = message.serialize()
        _ = try link.send(serialized)

        return seq
    }

    // MARK: - Receiving

    /// Handle incoming data on the channel.
    func handleIncoming(_ data: Data) {
        guard let message = Message.deserialize(data) else { return }

        // Call type-specific handler if registered
        if let handler = handlers[message.type] {
            handler(message)
        }

        // Call general message callback
        messageCallback?(message)
    }

    // MARK: - Handler Registration

    /// Register a handler for a specific message type.
    public func registerHandler(type: UInt16, handler: @escaping (Message) -> Void) {
        handlers[type] = handler
    }

    /// Remove a handler for a message type.
    public func removeHandler(type: UInt16) {
        handlers.removeValue(forKey: type)
    }
}

// MARK: - Errors

public enum RNSChannelError: Error, LocalizedError {
    case noLink
    case sendFailed

    public var errorDescription: String? {
        switch self {
        case .noLink: return "Channel has no active link"
        case .sendFailed: return "Failed to send channel message"
        }
    }
}
