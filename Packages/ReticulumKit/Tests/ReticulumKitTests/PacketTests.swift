// SPDX-License-Identifier: MIT
// ReticulumKitTests — PacketTests.swift

import XCTest
@testable import ReticulumKit

final class PacketTests: XCTestCase {

    func testPacketPackUnpack() throws {
        let destHash = RNSCrypto.randomBytes(count: RNS.truncatedHashLength)
        let payload = Data("test payload".utf8)

        let packet = RNSPacket(
            headerType: .type1,
            propagationType: .broadcast,
            destinationType: .single,
            packetType: .data,
            hops: 3,
            destinationHash: destHash,
            context: .none,
            data: payload
        )

        let packed = packet.pack()
        let unpacked = try RNSPacket.unpack(packed)

        XCTAssertEqual(unpacked.headerType, .type1)
        XCTAssertEqual(unpacked.propagationType, .broadcast)
        XCTAssertEqual(unpacked.destinationType, .single)
        XCTAssertEqual(unpacked.packetType, .data)
        XCTAssertEqual(unpacked.hops, 3)
        XCTAssertEqual(unpacked.destinationHash, destHash)
        XCTAssertEqual(unpacked.context, .none)
        XCTAssertEqual(unpacked.data, payload)
    }

    func testType2Packet() throws {
        let destHash = RNSCrypto.randomBytes(count: RNS.truncatedHashLength)
        let transportId = RNSCrypto.randomBytes(count: RNS.truncatedHashLength)
        let payload = Data("transport packet".utf8)

        let packet = RNSPacket(
            headerType: .type2,
            propagationType: .transport,
            destinationType: .single,
            packetType: .data,
            hops: 1,
            destinationHash: destHash,
            transportId: transportId,
            context: .none,
            data: payload
        )

        let packed = packet.pack()
        let unpacked = try RNSPacket.unpack(packed)

        XCTAssertEqual(unpacked.headerType, .type2)
        XCTAssertEqual(unpacked.transportId, transportId)
        XCTAssertEqual(unpacked.destinationHash, destHash)
        XCTAssertEqual(unpacked.data, payload)
    }

    func testAnnouncePacket() throws {
        let identity = RNSIdentity()
        let destination = RNSDestination(
            identity: identity,
            appName: "test.app"
        )

        let announceData = try destination.announce()
        let packet = RNSPacket.announce(from: destination, data: announceData)

        XCTAssertEqual(packet.packetType, .announce)
        XCTAssertEqual(packet.propagationType, .broadcast)
        XCTAssertEqual(packet.destinationHash, destination.hash)
        XCTAssertTrue(packet.data.count > RNS.identityKeySize) // pub key + name hash + random + sig
    }

    func testLinkRequestPacket() {
        let identity = RNSIdentity()
        let destination = RNSDestination(
            identity: identity,
            appName: "test.app"
        )
        let data = RNSCrypto.randomBytes(count: 96)

        let packet = RNSPacket.linkRequest(to: destination, data: data)
        XCTAssertEqual(packet.packetType, .linkRequest)
        XCTAssertEqual(packet.destinationType, .single)
    }

    func testPacketHash() {
        let destHash = RNSCrypto.randomBytes(count: RNS.truncatedHashLength)
        let packet = RNSPacket(
            destinationHash: destHash,
            data: Data("test".utf8)
        )

        let hash = packet.packetHash
        XCTAssertEqual(hash.count, RNS.truncatedHashLength)
    }

    func testTooShortPacket() {
        let data = Data([0x00])
        XCTAssertThrowsError(try RNSPacket.unpack(data))
    }

    func testEmptyPayload() throws {
        let destHash = RNSCrypto.randomBytes(count: RNS.truncatedHashLength)
        let packet = RNSPacket(
            destinationHash: destHash,
            data: Data()
        )

        let packed = packet.pack()
        let unpacked = try RNSPacket.unpack(packed)
        XCTAssertTrue(unpacked.data.isEmpty)
    }
}
