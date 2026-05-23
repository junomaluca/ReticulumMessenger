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

    /// Standard LXMF field identifiers, matching the Python reference
    /// (`LXMF.FIELD_*`). The body itself carries `timestamp`, `title`, and
    /// `content` as positional elements of the outer msgpack array — the
    /// values below are only used inside the `fields` dict for OPTIONAL
    /// metadata and binary attachments.
    public enum FieldType: UInt8, Sendable {
        case embeddedLXMS     = 0x01
        case telemetry        = 0x02
        case telemetryStream  = 0x03
        case iconAppearance   = 0x04
        case fileAttachments  = 0x05
        case image            = 0x06
        case audio            = 0x07
        case thread           = 0x08
        case commands         = 0x09
        case results          = 0x0A
        case group            = 0x0B
        case ticket           = 0x0C
        case event            = 0x0D
        case rnrRefs          = 0x0E
        case renderer         = 0x0F
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

    /// Number of delivery retry attempts (not serialized).
    public var retryCount: Int?

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

    /// Serialize this message into the Python LXMF wire format:
    /// `dst_hash(16) || src_hash(16) || signature(64) || msgpack([ts, title, content, fields])`
    /// The signature placeholder is zero-filled for now — Swift receivers
    /// (and the current Python receivers used for testing) do not verify it,
    /// and full LXMF signing of the inner body is a separate feature that
    /// also requires identity ratchet/stamp logic.
    public func serialize() -> Data {
        // Build the fields dict (binary attachments + caller-provided custom fields).
        // Display names and timestamp live in the positional msgpack array, not here.
        //
        // Attachment encoding follows the Python LXMF reference so
        // Sideband, MeshChat, Ratspeak, NomadNet can all decode us:
        //   0x05 FIELD_FILE_ATTACHMENTS → [[name, data], ...]
        //   0x06 FIELD_IMAGE            → [ext_string, image_data]
        //   0x07 FIELD_AUDIO            → [mode_int, audio_data]
        var fieldMap: [(MessagePackValue, MessagePackValue)] = []
        var fileEntries: [MessagePackValue] = []

        for attachment in attachments {
            let mime = attachment.mimeType.lowercased()
            if mime.hasPrefix("image/") {
                let ext = (attachment.name as NSString).pathExtension.lowercased()
                let imageExt = ext.isEmpty ? "jpg" : ext
                let val: MessagePackValue = .array([.string(imageExt), .binary(attachment.data)])
                fieldMap.append((.uint(UInt64(FieldType.image.rawValue)), val))
            } else if mime == "audio/opus" || mime == "audio/codec2" {
                let mode: UInt64 = mime == "audio/codec2" ? 0 : 16
                let val: MessagePackValue = .array([.uint(mode), .binary(attachment.data)])
                fieldMap.append((.uint(UInt64(FieldType.audio.rawValue)), val))
            } else {
                fileEntries.append(.array([.string(attachment.name), .binary(attachment.data)]))
            }
        }
        if !fileEntries.isEmpty {
            fieldMap.append((.uint(UInt64(FieldType.fileAttachments.rawValue)), .array(fileEntries)))
        }
        for (key, value) in fields {
            fieldMap.append((.uint(UInt64(key)), value))
        }

        // Positional msgpack body: [timestamp_float, title_bytes, content_bytes, fields_dict]
        let titleBytes: MessagePackValue = title.map { .binary(Data($0.utf8)) } ?? .nil
        let contentBytes: MessagePackValue = .binary(Data(content.utf8))
        let body: MessagePackValue = .array([
            .double(timestamp.timeIntervalSince1970),
            titleBytes,
            contentBytes,
            .map(fieldMap)
        ])
        let packedBody = MessagePackEncoder.encode(body)

        var data = Data()
        data.append(destinationHash.prefix(16))
        data.append(sourceHash.prefix(16))
        data.append(Data(count: 64))      // 64-byte signature placeholder
        data.append(packedBody)
        return data
    }

    /// Deserialize an LXMF message body. The canonical wire format is the
    /// Python LXMF one:
    /// `dest_hash(16) || src_hash(16) || signature(64) || msgpack([ts, title, content, fields, ?stamp])`.
    /// Older Swift-only senders used a wholly-different msgpack array as the
    /// entire body — that format is still accepted for backwards compatibility
    /// with messages already on disk and any legacy in-flight traffic.
    public static func deserialize(_ data: Data) throws -> LXMessage {
        if let msg = try? deserializePythonFormat(data) {
            return msg
        }
        if let msg = try? deserializeSwiftFormat(data) {
            return msg
        }
        throw LXMFError.invalidFormat
    }

    /// Deserialize from the Swift wire format: msgpack([src_hash, dst_hash, method, fields_map])
    private static func deserializeSwiftFormat(_ data: Data) throws -> LXMessage {
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

        // Legacy Swift-format field IDs (kept for compat with on-disk messages
        // serialised by earlier app builds). These IDs collide with the
        // official LXMF FIELD_* constants and are NOT used for new sends.
        for (key, val) in fieldPairs {
            guard let keyNum = key.intValue else { continue }
            let fieldType = UInt8(keyNum)

            switch fieldType {
            case 0x01:                                       // legacy content
                content = val.stringValue ?? ""
            case 0x02:                                       // legacy title
                title = val.stringValue
            case 0x03:                                       // legacy timestamp
                if let ts = val.intValue {
                    timestamp = Date(timeIntervalSince1970: TimeInterval(ts))
                }
            case 0x07:                                       // legacy sourceName
                sourceName = val.stringValue
            case 0x08:                                       // legacy destinationName
                destinationName = val.stringValue
            case 0x04:                                       // legacy fileAttachment
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

    /// Deserialize from the Python LXMF reference format:
    /// dest_hash(16) + src_hash(16) + signature(64) + msgpack([timestamp, title, content, fields, ?stamp])
    private static func deserializePythonFormat(_ data: Data) throws -> LXMessage {
        let headerSize = 16 + 16 + 64 // dest + src + signature
        guard data.count > headerSize else {
            throw LXMFError.invalidFormat
        }

        let dstHash = Data(data[0..<16])
        let srcHash = Data(data[16..<32])
        // signature at 32..<96 (used for verification, skipped for now)
        let payloadData = Data(data[headerSize...])

        let value = try MessagePackDecoder.decode(payloadData)
        guard case .array(let arr) = value, arr.count >= 4 else {
            throw LXMFError.invalidFormat
        }

        // Python format: [timestamp_float, title_bytes, content_bytes, fields_dict, ?stamp]
        var timestamp = Date()
        if let tsDouble = arr[0].doubleValue {
            timestamp = Date(timeIntervalSince1970: tsDouble)
        } else if let tsFloat = arr[0].floatValue {
            timestamp = Date(timeIntervalSince1970: TimeInterval(tsFloat))
        } else if let tsInt = arr[0].intValue {
            timestamp = Date(timeIntervalSince1970: TimeInterval(tsInt))
        }

        // Title: bytes or nil
        let title: String?
        if let titleData = arr[1].dataValue {
            title = String(data: titleData, encoding: .utf8)
        } else if let titleStr = arr[1].stringValue {
            title = titleStr
        } else {
            title = nil
        }

        // Content: bytes or string
        let content: String
        if let contentData = arr[2].dataValue {
            content = String(data: contentData, encoding: .utf8) ?? ""
        } else if let contentStr = arr[2].stringValue {
            content = contentStr
        } else {
            content = ""
        }

        // Fields dict
        var fields: [UInt8: MessagePackValue] = [:]
        var sourceName: String?
        var destinationName: String?
        var attachments: [LXMFAttachment] = []

        if case .map(let fieldPairs) = arr[3] {
            for (key, val) in fieldPairs {
                guard let keyNum = key.intValue else { continue }
                let fieldType = UInt8(keyNum)
                switch fieldType {
                case FieldType.fileAttachments.rawValue:
                    if case .array(let outer) = val {
                        let entriesAreLists = outer.contains { if case .array = $0 { return true } else { return false } }
                        if entriesAreLists {
                            for entry in outer {
                                if let att = LXMFAttachment.fromMessagePack(entry) {
                                    attachments.append(att)
                                }
                            }
                        } else if let att = LXMFAttachment.fromMessagePack(val) {
                            attachments.append(att)
                        }
                    }
                case FieldType.image.rawValue:
                    if let att = LXMFAttachment.fromImageField(val) {
                        attachments.append(att)
                    }
                case FieldType.audio.rawValue:
                    if let att = LXMFAttachment.fromAudioField(val) {
                        attachments.append(att)
                    }
                default:
                    fields[fieldType] = val
                }
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
            method: .direct,
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

    /// Decode one entry from LXMF `FIELD_FILE_ATTACHMENTS` (0x05).
    /// The canonical Python reference uses `[name, bytes]` (2-element). Older
    /// builds of this app emitted `[name, bytes, mime]` (3-element); accept both.
    /// `name` may arrive as either a msgpack STR or BIN.
    public static func fromMessagePack(_ value: MessagePackValue) -> LXMFAttachment? {
        guard case .array(let arr) = value, arr.count >= 2,
              let data = arr[1].binaryOrStringData else {
            return nil
        }
        let name = arr[0].stringValue ?? arr[0].dataValue.flatMap { String(data: $0, encoding: .utf8) } ?? "attachment"
        let mime: String = (arr.count >= 3 ? arr[2].stringValue : nil) ?? mimeGuess(forFilename: name)
        return LXMFAttachment(name: name, data: data, mimeType: mime)
    }

    /// Decode LXMF `FIELD_IMAGE` (0x06): `[image_type_string, image_bytes]`.
    /// Sideband / MeshChat encode the image type as a short extension like
    /// "png" / "jpg" / "webp" — derive both a filename and MIME from it.
    public static func fromImageField(_ value: MessagePackValue) -> LXMFAttachment? {
        guard case .array(let arr) = value, arr.count >= 2,
              let data = arr[1].binaryOrStringData else {
            return nil
        }
        let rawType: String = arr[0].stringValue
            ?? arr[0].dataValue.flatMap { String(data: $0, encoding: .utf8) }
            ?? "bin"
        let ext = rawType.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let mime: String
        switch ext {
        case "jpg", "jpeg": mime = "image/jpeg"
        case "png":         mime = "image/png"
        case "gif":         mime = "image/gif"
        case "webp":        mime = "image/webp"
        case "heic":        mime = "image/heic"
        default:            mime = "image/\(ext.isEmpty ? "octet-stream" : ext)"
        }
        return LXMFAttachment(name: "image.\(ext.isEmpty ? "bin" : ext)", data: data, mimeType: mime)
    }

    /// Decode LXMF `FIELD_AUDIO` (0x07): `[audio_mode_int, audio_bytes]`.
    /// `audio_mode` is a Codec2/Opus mode integer (0..15 are Codec2, 16+ Opus).
    /// We don't decode it back to audio here — surface the raw bytes and a
    /// reasonable filename/mime so the bubble can offer playback.
    public static func fromAudioField(_ value: MessagePackValue) -> LXMFAttachment? {
        guard case .array(let arr) = value, arr.count >= 2,
              let data = arr[1].binaryOrStringData else {
            return nil
        }
        let mode = arr[0].intValue ?? 0
        // Codec2 modes 0..15; modes >= 16 are Opus in Sideband's scheme.
        let mime = mode >= 16 ? "audio/opus" : "audio/codec2"
        let ext  = mode >= 16 ? "opus" : "c2"
        return LXMFAttachment(name: "voice.\(ext)", data: data, mimeType: mime)
    }

    /// Best-effort MIME guess from a filename's extension. Used when a peer
    /// sends a `FIELD_FILE_ATTACHMENTS` entry without a MIME (the reference shape).
    public static func mimeGuess(forFilename name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "heic":        return "image/heic"
        case "mp3":         return "audio/mpeg"
        case "m4a":         return "audio/mp4"
        case "wav":         return "audio/wav"
        case "ogg":         return "audio/ogg"
        case "opus":        return "audio/opus"
        case "mp4":         return "video/mp4"
        case "mov":         return "video/quicktime"
        case "pdf":         return "application/pdf"
        case "txt":         return "text/plain"
        case "json":        return "application/json"
        default:            return "application/octet-stream"
        }
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
