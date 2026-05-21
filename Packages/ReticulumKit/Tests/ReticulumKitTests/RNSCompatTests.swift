// SPDX-License-Identifier: MIT
// ReticulumKitTests — RNSCompatTests.swift
//
// Cross-implementation vectors pinning the Swift stack to the reference
// Python RNS wire format. Regenerated with the helper script in the
// patch that introduced this file.

import XCTest
import CryptoKit
@testable import ReticulumKit

final class RNSCompatTests: XCTestCase {

    // Deterministic identity built from fixed Ed25519 + X25519 seeds.
    // Verified against Python RNS (sbapp 0.8.x) with the canonical pub-key
    // wire order (X25519 || Ed25519):
    //   identity_hash       56704ff241ebad97b7456a35aa265f13
    //   lxmf.delivery dest  279eca4ab2af7a1970bd51fd6323fd0b
    private static let sigSeed = Data([
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    ])
    private static let encSeed = Data([
        0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88,
        0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00,
        0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88,
        0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00,
    ])

    private func makeIdentity() throws -> RNSIdentity {
        var bytes = Data()
        bytes.append(Self.sigSeed)
        bytes.append(Self.encSeed)
        return try RNSIdentity(privateKeyBytes: bytes)
    }

    func testNameHashIs10Bytes() {
        XCTAssertEqual(RNS.nameHashLength, 10)
        let nh = RNSCrypto.nameHash("lxmf.delivery")
        XCTAssertEqual(nh.count, 10)
        XCTAssertEqual(nh.map { String(format: "%02x", $0) }.joined(),
                       "6ec60bc318e2c0f0d908")
    }

    func testIdentityHashMatchesRNS() throws {
        let identity = try makeIdentity()
        XCTAssertEqual(identity.hexHash, "56704ff241ebad97b7456a35aa265f13")
    }

    func testLXMFDeliveryDestinationHashMatchesRNS() throws {
        let identity = try makeIdentity()
        let dest = RNSDestination(identity: identity, appName: "lxmf", aspects: ["delivery"])
        XCTAssertEqual(dest.hexHash, "279eca4ab2af7a1970bd51fd6323fd0b")
    }

    /// PLAIN destination hash = SHA256(name_hash)[:16] where name_hash = SHA256(full_name)[:10].
    /// Verified against Python RNS Destination.hash("rnstransport", "path", "request").
    /// Computing SHA256(name)[:16] directly is the wrong formula and produces a hash
    /// no other RNS node recognises, breaking inbound and outbound path requests.
    func testPathRequestDestinationHashMatchesRNS() {
        let name = "rnstransport.path.request"
        let nameHash = Data(RNSCrypto.sha256(Data(name.utf8)).prefix(RNS.nameHashLength))
        let plainHash = Data(RNSCrypto.sha256(nameHash).prefix(RNS.truncatedHashLength))
        XCTAssertEqual(plainHash.map { String(format: "%02x", $0) }.joined(),
                       "6b9f66014d9853faab220fba47d02761")
    }

    func testAnnounceRoundTrip() throws {
        let identity = try makeIdentity()
        let dest = RNSDestination(identity: identity, appName: "lxmf", aspects: ["delivery"])
        let appData = Data("Test Peer".utf8)

        let announce = try dest.announce(appData: appData)

        // Field-by-field layout: pub(64) | name_hash(10) | random(10) | sig(64) | app_data
        XCTAssertEqual(announce.count, 64 + 10 + 10 + 64 + appData.count)

        // Parse back and verify signature.
        guard let parsed = RNSIdentity.parseAnnounce(
            data: announce,
            destinationHash: dest.hash,
            hasRatchet: false
        ) else {
            XCTFail("Announce failed to parse / verify")
            return
        }
        XCTAssertEqual(parsed.identity.hash, identity.hash)
        XCTAssertEqual(parsed.announce.appData, appData)
        XCTAssertNil(parsed.announce.ratchet)
    }

    func testAnnounceRejectsTampering() throws {
        let identity = try makeIdentity()
        let dest = RNSDestination(identity: identity, appName: "lxmf", aspects: ["delivery"])
        var announce = try dest.announce(appData: Data("hi".utf8))
        // Flip a byte in the public-key region — signature should fail.
        announce[5] ^= 0xFF
        XCTAssertNil(RNSIdentity.parseAnnounce(
            data: announce,
            destinationHash: dest.hash,
            hasRatchet: false
        ))
    }

    func testAnnounceWithRatchet() throws {
        let identity = try makeIdentity()
        let dest = RNSDestination(identity: identity, appName: "lxmf", aspects: ["delivery"])
        let ratchet = RNSCrypto.randomBytes(count: RNS.ratchetLength)
        let announce = try dest.announce(ratchet: ratchet, appData: nil)

        XCTAssertEqual(announce.count, 64 + 10 + 10 + 32 + 64)
        guard let parsed = RNSIdentity.parseAnnounce(
            data: announce,
            destinationHash: dest.hash,
            hasRatchet: true
        ) else {
            XCTFail("Ratcheted announce failed to verify")
            return
        }
        XCTAssertEqual(parsed.announce.ratchet, ratchet)
    }

    func testPacketFlagsByteLayout() throws {
        // Verify the 8 bits of the flags byte match the RNS layout.
        let destHash = Data(repeating: 0xAA, count: RNS.truncatedHashLength)
        let packet = RNSPacket(
            headerType: .type1,
            transportType: .transport,
            contextFlag: true,
            destinationType: .single,
            packetType: .announce,
            destinationHash: destHash,
            data: Data()
        )
        let packed = packet.pack()
        // Expected flags:
        //  headerType=0 (Type1) <<6 = 0b00000000
        //  contextFlag=1        <<5 = 0b00100000
        //  transportType=1      <<4 = 0b00010000
        //  destType=0 (single)  <<2 = 0b00000000
        //  packetType=1 (anno)      = 0b00000001
        //  -------------------------- 0b00110001 = 0x31
        XCTAssertEqual(packed[0], 0x31)

        let round = try RNSPacket.unpack(packed)
        XCTAssertEqual(round.headerType, .type1)
        XCTAssertTrue(round.contextFlag)
        XCTAssertEqual(round.transportType, .transport)
        XCTAssertEqual(round.destinationType, .single)
        XCTAssertEqual(round.packetType, .announce)
    }

    /// Pinned fixture: an announce built by Python RNS primitives for the
    /// seeded identity above, with `random_hash = aabbccddeeff00112233` and
    /// `app_data = "TestPeer"`. If our parser can verify this byte-for-byte,
    /// we know the on-wire layout and signed-material order match RNS.
    func testParsesAnnounceProducedByPythonRNS() throws {
        let dest = Data(hexEncoded: "7a35df0b1d858eced65beb2430782b4e")
        let announce = Data(hexEncoded:
            "3ccd241cffc9b3618044b97d036d8614593d8b017c340f1dee8773385517654b" +
            "4a52f593172fa3a7184e79ec52ffddcf8b6062c9a69054a606f07532e255746d" +
            "6ec60bc318e2c0f0d908aabbccddeeff001122336797784d1cf33663f59346c9" +
            "c0fc4a564e3679cb3eb3cd7885ffd0a5d9f3a1b785b19264c106ea5fa1ec147f" +
            "9def51a6bd16d3ca635c0f09913961ff1e01cc0a5465737450656572"
        )

        guard let parsed = RNSIdentity.parseAnnounce(
            data: announce,
            destinationHash: dest,
            hasRatchet: false
        ) else {
            XCTFail("Failed to verify a Python-RNS-produced announce")
            return
        }
        XCTAssertEqual(parsed.announce.nameHash.map { String(format: "%02x", $0) }.joined(),
                       "6ec60bc318e2c0f0d908")
        XCTAssertEqual(parsed.announce.appData, Data("TestPeer".utf8))
    }

    // MARK: - helpers

    func testAutoInterfaceMulticastGroup() {
        // Mirror the Python derivation for the default group_id "reticulum"
        // with temporary address type ("1") and link scope ("2").
        let g = [UInt8](SHA256.hash(data: Data("reticulum".utf8)))
        func word(_ hi: Int, _ lo: Int) -> String {
            String(format: "%x", (UInt16(g[hi]) << 8) | UInt16(g[lo]))
        }
        let expected = "ff12:0:" + [word(2,3), word(4,5), word(6,7),
                                     word(8,9), word(10,11), word(12,13)].joined(separator: ":")
        XCTAssertEqual(AutoInterface.defaultMulticastGroup, expected)
        XCTAssertTrue(AutoInterface.defaultMulticastGroup.hasPrefix("ff12:0:"))
    }
}

private extension Data {
    init(hexEncoded hex: String) {
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            data.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        self = data
    }
}
