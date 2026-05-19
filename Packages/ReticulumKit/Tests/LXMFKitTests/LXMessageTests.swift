// SPDX-License-Identifier: MIT
// LXMFKitTests — LXMessageTests.swift

import XCTest
@testable import LXMFKit
@testable import ReticulumKit

final class LXMessageTests: XCTestCase {

    func testMessageCreation() {
        let sourceHash = RNSCrypto.randomBytes(count: 16)
        let destHash = RNSCrypto.randomBytes(count: 16)

        let msg = LXMessage(
            sourceHash: sourceHash,
            destinationHash: destHash,
            content: "Hello from the mesh!"
        )

        XCTAssertEqual(msg.content, "Hello from the mesh!")
        XCTAssertEqual(msg.sourceHash, sourceHash)
        XCTAssertEqual(msg.destinationHash, destHash)
        XCTAssertEqual(msg.state, .new)
        XCTAssertFalse(msg.isIncoming)
        XCTAssertEqual(msg.id.count, 16)
    }

    func testMessageSerializationRoundTrip() throws {
        let sourceHash = RNSCrypto.randomBytes(count: 16)
        let destHash = RNSCrypto.randomBytes(count: 16)

        let original = LXMessage(
            sourceHash: sourceHash,
            destinationHash: destHash,
            content: "Test message",
            title: "Greeting"
        )

        let serialized = original.serialize()
        XCTAssertFalse(serialized.isEmpty)

        let restored = try LXMessage.deserialize(serialized)
        XCTAssertEqual(restored.content, "Test message")
        XCTAssertEqual(restored.title, "Greeting")
        XCTAssertEqual(restored.sourceHash, sourceHash)
        XCTAssertEqual(restored.destinationHash, destHash)
    }

    func testMessageWithSourceName() throws {
        let sourceHash = RNSCrypto.randomBytes(count: 16)
        let destHash = RNSCrypto.randomBytes(count: 16)

        var msg = LXMessage(
            sourceHash: sourceHash,
            destinationHash: destHash,
            content: "Named message"
        )
        msg.sourceName = "Alice"

        let serialized = msg.serialize()
        let restored = try LXMessage.deserialize(serialized)
        XCTAssertEqual(restored.sourceName, "Alice")
    }

    func testMessageHexHash() {
        let sourceHash = Data(repeating: 0xAB, count: 16)
        let destHash = Data(repeating: 0xCD, count: 16)

        let msg = LXMessage(
            sourceHash: sourceHash,
            destinationHash: destHash,
            content: "test"
        )

        XCTAssertEqual(msg.sourceHexHash, String(repeating: "ab", count: 16))
        XCTAssertEqual(msg.destinationHexHash, String(repeating: "cd", count: 16))
    }

    func testShortSourceHash() {
        let sourceHash = Data([0x12, 0x34, 0x56, 0x78] + Array(repeating: UInt8(0), count: 12))
        let destHash = RNSCrypto.randomBytes(count: 16)

        let msg = LXMessage(
            sourceHash: sourceHash,
            destinationHash: destHash,
            content: "test"
        )

        XCTAssertEqual(msg.shortSourceHash, "12345678")
    }

    func testDeliveryMethods() throws {
        let sourceHash = RNSCrypto.randomBytes(count: 16)
        let destHash = RNSCrypto.randomBytes(count: 16)

        for method in [LXMessage.Method.direct, .propagated] {
            let msg = LXMessage(
                sourceHash: sourceHash,
                destinationHash: destHash,
                content: "method test",
                method: method
            )

            let serialized = msg.serialize()
            let restored = try LXMessage.deserialize(serialized)
            XCTAssertEqual(restored.method, method)
        }
    }
}
