// SPDX-License-Identifier: MIT
// LXMFKitTests — MessagePackTests.swift

import XCTest
@testable import LXMFKit

final class MessagePackTests: XCTestCase {

    func testNil() throws {
        let encoded = MessagePackEncoder.encode(.nil)
        let decoded = try MessagePackDecoder.decode(encoded)
        XCTAssertTrue(decoded.isNil)
    }

    func testBool() throws {
        let trueEncoded = MessagePackEncoder.encode(.bool(true))
        let falseEncoded = MessagePackEncoder.encode(.bool(false))

        XCTAssertEqual(try MessagePackDecoder.decode(trueEncoded).boolValue, true)
        XCTAssertEqual(try MessagePackDecoder.decode(falseEncoded).boolValue, false)
    }

    func testPositiveInt() throws {
        // Fixint
        let small = MessagePackEncoder.encode(.uint(42))
        XCTAssertEqual(try MessagePackDecoder.decode(small), .uint(42))

        // UInt8
        let u8 = MessagePackEncoder.encode(.uint(200))
        XCTAssertEqual(try MessagePackDecoder.decode(u8), .uint(200))

        // UInt16
        let u16 = MessagePackEncoder.encode(.uint(1000))
        XCTAssertEqual(try MessagePackDecoder.decode(u16), .uint(1000))

        // UInt32
        let u32 = MessagePackEncoder.encode(.uint(100_000))
        XCTAssertEqual(try MessagePackDecoder.decode(u32), .uint(100_000))
    }

    func testNegativeInt() throws {
        // Negative fixint
        let small = MessagePackEncoder.encode(.int(-10))
        XCTAssertEqual(try MessagePackDecoder.decode(small), .int(-10))

        // Int8
        let i8 = MessagePackEncoder.encode(.int(-100))
        XCTAssertEqual(try MessagePackDecoder.decode(i8), .int(-100))

        // Int16
        let i16 = MessagePackEncoder.encode(.int(-1000))
        XCTAssertEqual(try MessagePackDecoder.decode(i16), .int(-1000))
    }

    func testString() throws {
        let short = MessagePackEncoder.encode(.string("hello"))
        XCTAssertEqual(try MessagePackDecoder.decode(short).stringValue, "hello")

        let empty = MessagePackEncoder.encode(.string(""))
        XCTAssertEqual(try MessagePackDecoder.decode(empty).stringValue, "")

        let longer = String(repeating: "x", count: 256)
        let encoded = MessagePackEncoder.encode(.string(longer))
        XCTAssertEqual(try MessagePackDecoder.decode(encoded).stringValue, longer)
    }

    func testBinary() throws {
        let data = Data([0x01, 0x02, 0x03, 0xFF])
        let encoded = MessagePackEncoder.encode(.binary(data))
        XCTAssertEqual(try MessagePackDecoder.decode(encoded).dataValue, data)
    }

    func testArray() throws {
        let arr: MessagePackValue = .array([.uint(1), .string("two"), .bool(true)])
        let encoded = MessagePackEncoder.encode(arr)
        let decoded = try MessagePackDecoder.decode(encoded)
        XCTAssertEqual(decoded, arr)
    }

    func testMap() throws {
        let map: MessagePackValue = .map([
            (.string("name"), .string("Alice")),
            (.string("age"), .uint(30)),
        ])
        let encoded = MessagePackEncoder.encode(map)
        let decoded = try MessagePackDecoder.decode(encoded)

        XCTAssertEqual(decoded["name"]?.stringValue, "Alice")
        XCTAssertEqual(decoded["age"]?.intValue, 30)
    }

    func testNestedStructure() throws {
        let value: MessagePackValue = .map([
            (.string("users"), .array([
                .map([(.string("name"), .string("Bob"))]),
                .map([(.string("name"), .string("Eve"))]),
            ])),
        ])

        let encoded = MessagePackEncoder.encode(value)
        let decoded = try MessagePackDecoder.decode(encoded)

        if case .array(let users) = decoded["users"] {
            XCTAssertEqual(users.count, 2)
            XCTAssertEqual(users[0]["name"]?.stringValue, "Bob")
        } else {
            XCTFail("Expected array")
        }
    }

    func testRoundTrip() throws {
        let values: [MessagePackValue] = [
            .nil,
            .bool(true),
            .int(-42),
            .uint(12345),
            .string("mesh networking"),
            .binary(Data(repeating: 0xAB, count: 100)),
            .array([.uint(1), .uint(2), .uint(3)]),
            .map([(.uint(1), .string("one"))]),
        ]

        for value in values {
            let encoded = MessagePackEncoder.encode(value)
            let decoded = try MessagePackDecoder.decode(encoded)
            XCTAssertEqual(decoded, value)
        }
    }
}
