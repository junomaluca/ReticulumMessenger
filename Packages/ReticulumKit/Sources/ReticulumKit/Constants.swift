// SPDX-License-Identifier: MIT
// ReticulumKit — Constants.swift
// Protocol constants matching the Reticulum Network Stack specification.

import Foundation

/// Core protocol constants for the Reticulum Network Stack.
public enum RNS {

    // MARK: - Version

    public static let protocolVersion: UInt8 = 1
    public static let wireFormatVersion: UInt8 = 0

    // MARK: - Cryptographic Sizes

    /// Truncated hash length in bits (used for addresses).
    public static let truncatedHashBits = 128
    /// Truncated hash length in bytes.
    public static let truncatedHashLength = truncatedHashBits / 8  // 16

    /// Size of each key (X25519/Ed25519) in bytes.
    public static let keySize = 32
    /// Full identity public key = Ed25519 pub (32) + X25519 pub (32).
    public static let identityKeySize = keySize * 2  // 64

    /// AES block size in bytes.
    public static let aesBlockSize = 16
    /// Fernet token overhead: version(1) + time(8) + IV(16) + HMAC(32).
    public static let fernetOverhead = 57

    // MARK: - Packet Constants

    /// Maximum packet data size in bytes.
    public static let mtu = 500
    /// Header size for a Type 1 packet (single destination).
    public static let header1Size = 2 + truncatedHashLength + 1  // 19
    /// Header size for a Type 2 packet (with transport).
    public static let header2Size = 2 + truncatedHashLength * 2 + 1  // 35
    /// Maximum payload for a Type 1 packet.
    public static let maxPayloadType1 = mtu - header1Size
    /// Maximum payload for a Type 2 packet.
    public static let maxPayloadType2 = mtu - header2Size

    // MARK: - Header Types

    public enum HeaderType: UInt8, Sendable {
        /// Normal packet with single address field.
        case type1 = 0x00
        /// Transport packet with two address fields.
        case type2 = 0x01
    }

    // MARK: - Propagation Types

    public enum PropagationType: UInt8, Sendable {
        case broadcast = 0x00
        case transport = 0x01
    }

    // MARK: - Destination Types

    public enum DestinationType: UInt8, Sendable {
        case single = 0x00
        case group = 0x01
        case plain = 0x02
        case link = 0x03
    }

    // MARK: - Packet Types

    public enum PacketType: UInt8, Sendable {
        case data = 0x00
        case announce = 0x01
        case linkRequest = 0x02
        case proof = 0x03
    }

    // MARK: - Packet Context

    public enum PacketContext: UInt8, Sendable {
        case none = 0x00
        case resource = 0x01
        case resourceAdvertisement = 0x02
        case resourceRequest = 0x03
        case resourceHashMap = 0x04
        case resourceProof = 0x05
        case resourceICL = 0x06
        case resourceReply = 0x07
        case cacheRequest = 0x08
        case request = 0x09
        case response = 0x0A
        case pathResponse = 0x0B
        case command = 0x0C
        case commandStatus = 0x0D
        case channel = 0x0E
        case keepalive = 0xFA
        case linkIdentify = 0xFB
        case linkClose = 0xFC
        case linkProof = 0xFD
        case lrProof = 0xFE
        case linkRequest_ = 0xFF  // Renamed to avoid conflict with PacketType
    }

    // MARK: - Link Constants

    public static let linkEstablishmentTimeout: TimeInterval = 15.0
    public static let linkKeepaliveInterval: TimeInterval = 360.0
    public static let linkStaleTime: TimeInterval = 720.0

    // MARK: - Transport Constants

    public static let announceCapExponent: UInt8 = 2
    public static let pathRequestTimeout: TimeInterval = 15.0
    public static let pathRequestGrace: TimeInterval = 0.35
    public static let pathRequestBlacklist: TimeInterval = 2.0

    // MARK: - Interface Constants

    public static let defaultTCPPort: UInt16 = 4242
    public static let reconnectDelay: TimeInterval = 5.0
    public static let maxReconnectDelay: TimeInterval = 300.0
}
