// SPDX-License-Identifier: MIT
// LXMFKit — LXMessage.swift
// LXMF (Lightweight Extensible Message Format) message type.

import Foundation
import ReticulumKit

/// An LXMF message — the fundamental unit of communication in the LXMF protocol.
/// Messages are structured containers with fields for content, metadata, and delivery info.
public struct LXMessage: Identifiable, Sendable {

    // MARK: - Types

    /// Delivery method for the message.
    public enum Method: UInt8, Sendable, Codable {
        case direct = 0x00      // Direct delivery via link
        case propagated = 0x01  // Via propagation node
        case paper = 0x02       // Paper message (QR code etc.)
    }

    /// Delivery state of the message.
    public enum State: String, Sendable, Codable {
        case new
        case draft
        case outbound
        case sending
        case sent
        case delivered
        case failed
        case received
    }

    /// Standard LXMF field identifiers.
    public enum FieldType: UInt8, Sendable {
        case content = 0x01
        case title = 0x02
        case timestamp = 0x03
        case fileAttachment = 0x04
        case image = 0x05
        case audio = 0x06
        case sourceName = 0x07
        case destinationName = 0x08
        case commands = 0x09
    }

    // MARK: - Properties

    /// Unique message identifier.
    public let id: Data

    /// Source destination hash (sender).
    public let sourceHash: Data

    /// Destination hash (recipient).
    public let destinationHash: Data

    /// Message delivery method.
    public var method: Method

    /// Current delivery state.
    public var state: State

    /// Message content (the text body).
    public var content: String

    /// Optional message title.
    public var title: String?

    /// When the message was created.
    public let timestamp: Date

    /// Source display name.
    public var sourceName: String?

    /// Destination display name.
    public var destinationName: String?

    /// Whether the message is incoming or outgoing.
    public var isIncoming: Bool

    /// Additional fields (extensible).
    public var fields: [UInt8: MessagePackValue]

    /// File attachments.
    public var attachments: [LXMFAttachment]

    /// Add an attachment to this message.
    public mutating func addAttachment(_ attachment: LXMFAttachment) {
        attachments.append(attachment)
    }

    // MARK: - Initialization

    /// Create a new outgoing message.
    public init(
        sourceHash: Data,
        destinationHash: Data,
        content: String,
        title: String? = nil,
        method: Method = .direct,
        fields: [UInt8: MessagePackValue] = [:],
        attachments: [LXMFAttachment] = []
    ) {
        self.id = RNSCrypto.randomBytes(count: 16)
        self.sourceHash = sourceHash
        self.destinationHash = destinationHash
        self.content = content
        self.title = title
        self.method = method
        self.state = .new
        self.timestamp = Date()
        self.isIncoming = false
        self.fields = fields
        self.attachments = attachments
    }

    /// Create a message from received LXMF data.
    public init(
        id: Data,
        sourceHash: Data,
        destinationHash: Data,
        content: String,
        title: String?,
        timestamp: Date,
        method: Method,
        fields: [UInt8: MessagePackValue]
    ) {
        self.id = id
        self.sourceHash = sourceHash
        self.destinationHash = destinationHash
        self.content = content
        self.title = title
        self.method = method
        self.state = .received
        self.timestamp = timestamp
        self.isIncoming = true
        self.fields = fields
        self.attachments = []
    }

    // MARK: - Serialization

    /// Serialize this message to LXMF wire format (MessagePack).
    public func serialize() -> Data {
        var fieldMap: [(MessagePackValue, MessagePackValue)] = []

        // Content
        fieldMap.append((.uint(UInt64(FieldType.content.rawValue)), .string(content)))

        // Title
        if let title = title {
            fieldMap.append((.uint(UInt64(FieldType.title.rawValue)), .string(title)))
        }

        // Timestamp
        let ts = Int64(timestamp.timeIntervalSince1970)
        fieldMap.append((.uint(UInt64(FieldType.timestamp.rawValue)), .int(ts)))

        // Source name
        if let name = sourceName {
            fieldMap.append((.uint(UInt64(FieldType.sourceName.rawValue)), .string(name)))
        }

        // Destination name
        if let name = destinationName {
            fieldMap.append((.uint(UInt64(FieldType.destinationName.rawValue)), .string(name)))
        }

        // File attachments
        for attachment in attachments {
            let attArray: MessagePackValue = .array([
                .string(attachment.name),
                .binary(attachment.data),
                .string(attachment.mimeType)
            ])
            fieldMap.append((.uint(UInt64(FieldType.fileAttachment.rawValue)), attArray))
        }

        // Additional fields
        for (key, value) in fields {
            fieldMap.append((.uint(UInt64(key)), value))
        }

        // LXMF message format: [source_hash, dest_hash, method, fields_map]
        let message: MessagePackValue = .array([
            .binary(sourceHash),
            .binary(destinationHash),
            .uint(UInt64(method.rawValue)),
            .map(fieldMap)
        ])

        return MessagePackEncoder.encode(message)
    }

    /// Deserialize an LXMF message from wire format.
    public static func deserialize(_ data: Data) throws -> LXMessage {
        let value = try MessagePackDecoder.decode(data)

        guard case .array(let arr) = value, arr.count >= 4 else {
            throw LXMFError.invalidFormat
        }

        guard let srcHash = arr[0].dataValue,
              let dstHash = arr[1].dataValue,
              let methodRaw = arr[2].intValue,
              let method = Method(rawValue: UInt8(methodRaw)),
              case .map(let fieldPairs) = arr[3] else {
            throw LXMFError.invalidFormat
        }

        var content = ""
        var title: String?
        var timestamp = Date()
        var sourceName: String?
        var destinationName: String?
        var fields: [UInt8: MessagePackValue] = [:]
        var attachments: [LXMFAttachment] = []

        for (key, val) in fieldPairs {
            guard let keyNum = key.intValue else { continue }
            let fieldType = UInt8(keyNum)

            switch fieldType {
            case FieldType.content.rawValue:
                content = val.stringValue ?? ""
            case FieldType.title.rawValue:
                title = val.stringValue
            case FieldType.timestamp.rawValue:
                if let ts = val.intValue {
                    timestamp = Date(timeIntervalSince1970: TimeInterval(ts))
                }
            case FieldType.sourceName.rawValue:
                sourceName = val.stringValue
            case FieldType.destinationName.rawValue:
                destinationName = val.stringValue
            case FieldType.fileAttachment.rawValue:
                if let att = LXMFAttachment.fromMessagePack(val) {
                    attachments.append(att)
                }
            default:
                fields[fieldType] = val
            }
        }

        let msgId = RNSCrypto.truncatedHash(data)

        var msg = LXMessage(
            id: msgId,
            sourceHash: srcHash,
            destinationHash: dstHash,
            content: content,
            title: title,
            timestamp: timestamp,
            method: method,
            fields: fields
        )
        msg.sourceName = sourceName
        msg.destinationName = destinationName
        msg.attachments = attachments

        return msg
    }

    // MARK: - Display Helpers

    /// Hex string of the message ID.
    public var hexId: String {
        id.map { String(format: "%02x", $0) }.joined()
    }

    /// Hex string of the source hash.
    public var sourceHexHash: String {
        sourceHash.map { String(format: "%02x", $0) }.joined()
    }

    /// Hex string of the destination hash.
    public var destinationHexHash: String {
        destinationHash.map { String(format: "%02x", $0) }.joined()
    }

    /// Short display hash (first 8 chars).
    public var shortSourceHash: String {
        String(sourceHexHash.prefix(8))
    }
}

// MARK: - Attachment

/// A file attachment within an LXMF message.
public struct LXMFAttachment: Sendable, Identifiable {
    public let id = UUID()
    public let name: String
    public let data: Data
    public let mimeType: String

    public init(name: String, data: Data, mimeType: String = "application/octet-stream") {
        self.name = name
        self.data = data
        self.mimeType = mimeType
    }

    public init(data: Data, mimeType: String, filename: String? = nil) {
        self.name = filename ?? "attachment"
        self.data = data
        self.mimeType = mimeType
    }

    static func fromMessagePack(_ value: MessagePackValue) -> LXMFAttachment? {
        guard case .array(let arr) = value, arr.count >= 3,
              let name = arr[0].stringValue,
              let data = arr[1].dataValue,
              let mime = arr[2].stringValue else {
            return nil
        }
        return LXMFAttachment(name: name, data: data, mimeType: mime)
    }
}

// MARK: - Errors

public enum LXMFError: Error, LocalizedError {
    case invalidFormat
    case deliveryFailed(String)
    case noRoute
    case encryptionFailed
    case deserializationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Invalid LXMF message format"
        case .deliveryFailed(let msg): return "Delivery failed: \(msg)"
        case .noRoute: return "No route to destination"
        case .encryptionFailed: return "Message encryption failed"
        case .deserializationFailed: return "Failed to deserialize message"
        }
    }
}
