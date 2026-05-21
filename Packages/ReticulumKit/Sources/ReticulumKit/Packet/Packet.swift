// SPDX-License-Identifier: MIT
// ReticulumKit — Packet.swift
// Reticulum wire-format packet encoding and decoding.

import Foundation

/// Represents a Reticulum network packet.
/// Packets are the fundamental unit of communication on the network.
///
/// Wire format:
/// ```
/// Type 1: [Header 1B][Hops 1B][Dest Hash 16B][Context 1B][Data ...]
/// Type 2: [Header 1B][Hops 1B][Transport ID 16B][Dest Hash 16B][Context 1B][Data ...]
/// ```
public struct RNSPacket: Sendable {

    // MARK: - Properties

    /// Header type (type1 = single address, type2 = transport with two addresses).
    public var headerType: RNS.HeaderType

    /// Propagation type.
    public var propagationType: RNS.PropagationType

    /// Destination type.
    public var destinationType: RNS.DestinationType

    /// Packet type.
    public var packetType: RNS.PacketType

    /// Hop count — incremented at each transport node.
    public var hops: UInt8

    /// Destination hash (16 bytes).
    public var destinationHash: Data

    /// Transport ID (16 bytes, only for type2 packets).
    public var transportId: Data?

    /// Packet context byte.
    public var context: RNS.PacketContext

    /// Context flag from header byte (bit 5). In announces, signals ratchet presence.
    public var contextFlag: Bool

    /// Packet payload data.
    public var data: Data

    /// The raw bytes of this packet (set after packing or receiving).
    public private(set) var raw: Data?

    /// Hash of this specific packet (for deduplication).
    public var packetHash: Data {
        guard let raw = raw else {
            return RNSCrypto.truncatedHash(pack())
        }
        return RNSCrypto.truncatedHash(raw)
    }

    // MARK: - Initialization

    public init(
        headerType: RNS.HeaderType = .type1,
        propagationType: RNS.PropagationType = .broadcast,
        destinationType: RNS.DestinationType = .single,
        packetType: RNS.PacketType = .data,
        hops: UInt8 = 0,
        destinationHash: Data,
        transportId: Data? = nil,
        context: RNS.PacketContext = .none,
        contextFlag: Bool = false,
        data: Data
    ) {
        self.headerType = headerType
        self.propagationType = propagationType
        self.destinationType = destinationType
        self.packetType = packetType
        self.hops = hops
        self.destinationHash = destinationHash
        self.transportId = transportId
        self.context = context
        self.contextFlag = contextFlag
        self.data = data
    }

    /// Create a data packet to a destination.
    public static func data(
        to destination: RNSDestination,
        data: Data,
        context: RNS.PacketContext = .none
    ) -> RNSPacket {
        RNSPacket(
            destinationType: destination.type,
            packetType: .data,
            destinationHash: destination.hash,
            context: context,
            data: data
        )
    }

    /// Create an announce packet.
    public static func announce(
        from destination: RNSDestination,
        data: Data
    ) -> RNSPacket {
        RNSPacket(
            propagationType: .broadcast,
            destinationType: destination.type,
            packetType: .announce,
            destinationHash: destination.hash,
            data: data
        )
    }

    /// Create a link request packet.
    public static func linkRequest(
        to destination: RNSDestination,
        data: Data
    ) -> RNSPacket {
        RNSPacket(
            destinationType: .single,
            packetType: .linkRequest,
            destinationHash: destination.hash,
            data: data
        )
    }

    // MARK: - Encoding

    /// Encode this packet into wire format bytes.
    public func pack() -> Data {
        var result = Data()

        // Header byte: [IFAC:1][HeaderType:1][PropType:2][DestType:2][PacketType:2]
        // Header byte layout (Python reference):
        // Bit 7: IFAC flag (0 = no IFAC)
        // Bit 6: Header type (0 = type1, 1 = type2)
        // Bit 5: Context flag (1 = ratchet present in announces)
        // Bit 4: Propagation type (0 = broadcast, 1 = transport)
        // Bits 3-2: Destination type
        // Bits 1-0: Packet type
        let contextFlagBit: UInt8 = contextFlag ? 1 : 0
        let header: UInt8 =
            (headerType.rawValue << 6) |
            (contextFlagBit << 5) |
            (propagationType.rawValue << 4) |
            (destinationType.rawValue << 2) |
            packetType.rawValue
        result.append(header)

        // Hops
        result.append(hops)

        // Transport ID (only for type2)
        if headerType == .type2, let transportId = transportId {
            result.append(transportId.prefix(RNS.truncatedHashLength))
        }

        // Destination hash
        result.append(destinationHash.prefix(RNS.truncatedHashLength))

        // Context
        result.append(context.rawValue)

        // Data
        result.append(data)

        return result
    }

    // MARK: - Decoding

    /// Decode a packet from raw wire-format bytes.
    public static func unpack(_ rawData: Data) throws -> RNSPacket {
        guard rawData.count >= 4 else {
            throw RNSPacketError.tooShort
        }

        let header = rawData[0]
        let hops = rawData[1]

        // Bit 7 is the IFAC flag (Interface Access Code). We don't support IFAC
        // processing, but must not conflate it with the header type (bit 6 only).
        let ifacFlag = (header >> 7) & 0x01
        if ifacFlag == 1 {
            // IFAC-tagged packets can't be parsed without the IFAC key/size config.
            throw RNSPacketError.tooShort
        }

        let headerTypeRaw = (header >> 6) & 0x01
        let contextFlagBit = (header >> 5) & 0x01
        let propTypeRaw = (header >> 4) & 0x01
        let destTypeRaw = (header >> 2) & 0x03
        let pktTypeRaw = header & 0x03

        guard let headerType = RNS.HeaderType(rawValue: headerTypeRaw) else {
            throw RNSPacketError.invalidHeaderType
        }
        guard let propType = RNS.PropagationType(rawValue: propTypeRaw) else {
            throw RNSPacketError.invalidPropagationType
        }
        guard let destType = RNS.DestinationType(rawValue: destTypeRaw) else {
            throw RNSPacketError.invalidDestinationType
        }
        guard let pktType = RNS.PacketType(rawValue: pktTypeRaw) else {
            throw RNSPacketError.invalidPacketType
        }

        var offset = 2
        var transportId: Data?

        if headerType == .type2 {
            guard rawData.count >= offset + RNS.truncatedHashLength else {
                throw RNSPacketError.tooShort
            }
            transportId = rawData[offset..<(offset + RNS.truncatedHashLength)]
            offset += RNS.truncatedHashLength
        }

        guard rawData.count >= offset + RNS.truncatedHashLength + 1 else {
            throw RNSPacketError.tooShort
        }

        let destHash = Data(rawData[offset..<(offset + RNS.truncatedHashLength)])
        offset += RNS.truncatedHashLength

        let contextRaw = rawData[offset]
        let context = RNS.PacketContext(rawValue: contextRaw) ?? .none
        offset += 1

        let data = rawData.count > offset ? Data(rawData[offset...]) : Data()

        var packet = RNSPacket(
            headerType: headerType,
            propagationType: propType,
            destinationType: destType,
            packetType: pktType,
            hops: hops,
            destinationHash: destHash,
            transportId: transportId.map { Data($0) },
            context: context,
            contextFlag: contextFlagBit == 1,
            data: data
        )
        packet.raw = rawData
        return packet
    }
}

// MARK: - Errors

public enum RNSPacketError: Error, LocalizedError {
    case tooShort
    case invalidHeaderType
    case invalidPropagationType
    case invalidDestinationType
    case invalidPacketType
    case payloadTooLarge

    public var errorDescription: String? {
        switch self {
        case .tooShort: return "Packet data too short"
        case .invalidHeaderType: return "Invalid header type"
        case .invalidPropagationType: return "Invalid propagation type"
        case .invalidDestinationType: return "Invalid destination type"
        case .invalidPacketType: return "Invalid packet type"
        case .payloadTooLarge: return "Payload exceeds MTU"
        }
    }
}
