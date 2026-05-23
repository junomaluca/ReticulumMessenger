// SPDX-License-Identifier: MIT
// LXMFKit — MessagePack.swift
// Minimal MessagePack encoder/decoder for LXMF message serialization.
// Implements the subset of MessagePack needed by the LXMF protocol.

import Foundation

/// Represents a MessagePack value.
public enum MessagePackValue: Sendable, Equatable {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Float)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    case map([(MessagePackValue, MessagePackValue)])

    // MARK: - Convenience Accessors

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let i) = self { return i }
        if case .uint(let u) = self { return Int64(exactly: u) }
        return nil
    }

    public var dataValue: Data? {
        if case .binary(let d) = self { return d }
        return nil
    }

    /// Like `dataValue` but also accepts a msgpack STR — some LXMF
    /// implementations encode binary payloads as STR instead of BIN.
    public var binaryOrStringData: Data? {
        if case .binary(let d) = self { return d }
        if case .string(let s) = self { return Data(s.utf8) }
        return nil
    }

    public var arrayValue: [MessagePackValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let d) = self { return d }
        if case .float(let f) = self { return Double(f) }
        if case .uint(let u) = self { return Double(u) }
        if case .int(let i) = self { return Double(i) }
        return nil
    }

    public var floatValue: Float? {
        if case .float(let f) = self { return f }
        if case .double(let d) = self { return Float(d) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var isNil: Bool {
        if case .nil = self { return true }
        return false
    }

    /// Dictionary-style access for map values.
    public subscript(key: String) -> MessagePackValue? {
        guard case .map(let pairs) = self else { return nil }
        for (k, v) in pairs {
            if case .string(let s) = k, s == key { return v }
        }
        return nil
    }

    // Equatable for maps (order-independent is complex, so we do ordered)
    public static func == (lhs: MessagePackValue, rhs: MessagePackValue) -> Bool {
        switch (lhs, rhs) {
        case (.nil, .nil): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.uint(let a), .uint(let b)): return a == b
        case (.float(let a), .float(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.binary(let a), .binary(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.map(let a), .map(let b)):
            guard a.count == b.count else { return false }
            for (pair1, pair2) in zip(a, b) {
                if pair1.0 != pair2.0 || pair1.1 != pair2.1 { return false }
            }
            return true
        default: return false
        }
    }
}

// MARK: - Encoder

public enum MessagePackEncoder {

    /// Encode a MessagePack value to binary data.
    public static func encode(_ value: MessagePackValue) -> Data {
        var data = Data()
        encodeValue(value, into: &data)
        return data
    }

    private static func encodeValue(_ value: MessagePackValue, into data: inout Data) {
        switch value {
        case .nil:
            data.append(0xC0)

        case .bool(let b):
            data.append(b ? 0xC3 : 0xC2)

        case .int(let i):
            encodeInt(i, into: &data)

        case .uint(let u):
            encodeUInt(u, into: &data)

        case .float(let f):
            data.append(0xCA)
            var bits = f.bitPattern.bigEndian
            data.append(Data(bytes: &bits, count: 4))

        case .double(let d):
            data.append(0xCB)
            var bits = d.bitPattern.bigEndian
            data.append(Data(bytes: &bits, count: 8))

        case .string(let s):
            let bytes = Data(s.utf8)
            encodeStringHeader(count: bytes.count, into: &data)
            data.append(bytes)

        case .binary(let b):
            encodeBinaryHeader(count: b.count, into: &data)
            data.append(b)

        case .array(let arr):
            encodeArrayHeader(count: arr.count, into: &data)
            for item in arr {
                encodeValue(item, into: &data)
            }

        case .map(let pairs):
            encodeMapHeader(count: pairs.count, into: &data)
            for (key, val) in pairs {
                encodeValue(key, into: &data)
                encodeValue(val, into: &data)
            }
        }
    }

    private static func encodeInt(_ i: Int64, into data: inout Data) {
        if i >= 0 {
            encodeUInt(UInt64(i), into: &data)
        } else if i >= -32 {
            data.append(UInt8(bitPattern: Int8(i)))
        } else if i >= Int64(Int8.min) {
            data.append(0xD0)
            data.append(UInt8(bitPattern: Int8(i)))
        } else if i >= Int64(Int16.min) {
            data.append(0xD1)
            var val = Int16(i).bigEndian
            data.append(Data(bytes: &val, count: 2))
        } else if i >= Int64(Int32.min) {
            data.append(0xD2)
            var val = Int32(i).bigEndian
            data.append(Data(bytes: &val, count: 4))
        } else {
            data.append(0xD3)
            var val = i.bigEndian
            data.append(Data(bytes: &val, count: 8))
        }
    }

    private static func encodeUInt(_ u: UInt64, into data: inout Data) {
        if u <= 0x7F {
            data.append(UInt8(u))
        } else if u <= UInt64(UInt8.max) {
            data.append(0xCC)
            data.append(UInt8(u))
        } else if u <= UInt64(UInt16.max) {
            data.append(0xCD)
            var val = UInt16(u).bigEndian
            data.append(Data(bytes: &val, count: 2))
        } else if u <= UInt64(UInt32.max) {
            data.append(0xCE)
            var val = UInt32(u).bigEndian
            data.append(Data(bytes: &val, count: 4))
        } else {
            data.append(0xCF)
            var val = u.bigEndian
            data.append(Data(bytes: &val, count: 8))
        }
    }

    private static func encodeStringHeader(count: Int, into data: inout Data) {
        if count <= 31 {
            data.append(0xA0 | UInt8(count))
        } else if count <= Int(UInt8.max) {
            data.append(0xD9)
            data.append(UInt8(count))
        } else if count <= Int(UInt16.max) {
            data.append(0xDA)
            var val = UInt16(count).bigEndian
            data.append(Data(bytes: &val, count: 2))
        } else {
            data.append(0xDB)
            var val = UInt32(count).bigEndian
            data.append(Data(bytes: &val, count: 4))
        }
    }

    private static func encodeBinaryHeader(count: Int, into data: inout Data) {
        if count <= Int(UInt8.max) {
            data.append(0xC4)
            data.append(UInt8(count))
        } else if count <= Int(UInt16.max) {
            data.append(0xC5)
            var val = UInt16(count).bigEndian
            data.append(Data(bytes: &val, count: 2))
        } else {
            data.append(0xC6)
            var val = UInt32(count).bigEndian
            data.append(Data(bytes: &val, count: 4))
        }
    }

    private static func encodeArrayHeader(count: Int, into data: inout Data) {
        if count <= 15 {
            data.append(0x90 | UInt8(count))
        } else if count <= Int(UInt16.max) {
            data.append(0xDC)
            var val = UInt16(count).bigEndian
            data.append(Data(bytes: &val, count: 2))
        } else {
            data.append(0xDD)
            var val = UInt32(count).bigEndian
            data.append(Data(bytes: &val, count: 4))
        }
    }

    private static func encodeMapHeader(count: Int, into data: inout Data) {
        if count <= 15 {
            data.append(0x80 | UInt8(count))
        } else if count <= Int(UInt16.max) {
            data.append(0xDE)
            var val = UInt16(count).bigEndian
            data.append(Data(bytes: &val, count: 2))
        } else {
            data.append(0xDF)
            var val = UInt32(count).bigEndian
            data.append(Data(bytes: &val, count: 4))
        }
    }
}

// MARK: - Decoder

public enum MessagePackDecoder {

    /// Decode a MessagePack value from binary data.
    public static func decode(_ data: Data) throws -> MessagePackValue {
        var offset = 0
        return try decodeValue(from: data, offset: &offset)
    }

    /// Decode multiple values from data.
    public static func decodeAll(_ data: Data) throws -> [MessagePackValue] {
        var offset = 0
        var values: [MessagePackValue] = []
        while offset < data.count {
            values.append(try decodeValue(from: data, offset: &offset))
        }
        return values
    }

    private static func decodeValue(from data: Data, offset: inout Int) throws -> MessagePackValue {
        guard offset < data.count else { throw MessagePackError.unexpectedEnd }

        let byte = data[offset]
        offset += 1

        // Positive fixint (0x00 - 0x7F)
        if byte <= 0x7F { return .uint(UInt64(byte)) }
        // Negative fixint (0xE0 - 0xFF)
        if byte >= 0xE0 { return .int(Int64(Int8(bitPattern: byte))) }
        // Fixmap (0x80 - 0x8F)
        if byte & 0xF0 == 0x80 { return try decodeMap(count: Int(byte & 0x0F), from: data, offset: &offset) }
        // Fixarray (0x90 - 0x9F)
        if byte & 0xF0 == 0x90 { return try decodeArray(count: Int(byte & 0x0F), from: data, offset: &offset) }
        // Fixstr (0xA0 - 0xBF)
        if byte & 0xE0 == 0xA0 { return try decodeString(count: Int(byte & 0x1F), from: data, offset: &offset) }

        switch byte {
        case 0xC0: return .nil
        case 0xC2: return .bool(false)
        case 0xC3: return .bool(true)

        // Binary
        case 0xC4: return try decodeBinary(countBytes: 1, from: data, offset: &offset)
        case 0xC5: return try decodeBinary(countBytes: 2, from: data, offset: &offset)
        case 0xC6: return try decodeBinary(countBytes: 4, from: data, offset: &offset)

        // Float
        case 0xCA:
            let bits = try readUInt32(from: data, offset: &offset)
            return .float(Float(bitPattern: bits))
        case 0xCB:
            let bits = try readUInt64(from: data, offset: &offset)
            return .double(Double(bitPattern: bits))

        // Unsigned int
        case 0xCC: return .uint(UInt64(try readUInt8(from: data, offset: &offset)))
        case 0xCD: return .uint(UInt64(try readUInt16(from: data, offset: &offset)))
        case 0xCE: return .uint(UInt64(try readUInt32(from: data, offset: &offset)))
        case 0xCF: return .uint(try readUInt64(from: data, offset: &offset))

        // Signed int
        case 0xD0:
            let v = try readUInt8(from: data, offset: &offset)
            return .int(Int64(Int8(bitPattern: v)))
        case 0xD1:
            let v = try readUInt16(from: data, offset: &offset)
            return .int(Int64(Int16(bitPattern: v)))
        case 0xD2:
            let v = try readUInt32(from: data, offset: &offset)
            return .int(Int64(Int32(bitPattern: v)))
        case 0xD3:
            let v = try readUInt64(from: data, offset: &offset)
            return .int(Int64(bitPattern: v))

        // String
        case 0xD9:
            let count = Int(try readUInt8(from: data, offset: &offset))
            return try decodeString(count: count, from: data, offset: &offset)
        case 0xDA:
            let count = Int(try readUInt16(from: data, offset: &offset))
            return try decodeString(count: count, from: data, offset: &offset)
        case 0xDB:
            let count = Int(try readUInt32(from: data, offset: &offset))
            return try decodeString(count: count, from: data, offset: &offset)

        // Array
        case 0xDC:
            let count = Int(try readUInt16(from: data, offset: &offset))
            return try decodeArray(count: count, from: data, offset: &offset)
        case 0xDD:
            let count = Int(try readUInt32(from: data, offset: &offset))
            return try decodeArray(count: count, from: data, offset: &offset)

        // Map
        case 0xDE:
            let count = Int(try readUInt16(from: data, offset: &offset))
            return try decodeMap(count: count, from: data, offset: &offset)
        case 0xDF:
            let count = Int(try readUInt32(from: data, offset: &offset))
            return try decodeMap(count: count, from: data, offset: &offset)

        default:
            throw MessagePackError.unsupportedType(byte)
        }
    }

    // MARK: - Read Helpers

    private static func readUInt8(from data: Data, offset: inout Int) throws -> UInt8 {
        guard offset < data.count else { throw MessagePackError.unexpectedEnd }
        let v = data[offset]
        offset += 1
        return v
    }

    private static func readUInt16(from data: Data, offset: inout Int) throws -> UInt16 {
        guard offset + 2 <= data.count else { throw MessagePackError.unexpectedEnd }
        let v = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        offset += 2
        return v
    }

    private static func readUInt32(from data: Data, offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw MessagePackError.unexpectedEnd }
        let v = UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
                UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
        offset += 4
        return v
    }

    private static func readUInt64(from data: Data, offset: inout Int) throws -> UInt64 {
        guard offset + 8 <= data.count else { throw MessagePackError.unexpectedEnd }
        var v: UInt64 = 0
        for i in 0..<8 {
            v = v << 8 | UInt64(data[offset + i])
        }
        offset += 8
        return v
    }

    private static func decodeString(count: Int, from data: Data, offset: inout Int) throws -> MessagePackValue {
        guard offset + count <= data.count else { throw MessagePackError.unexpectedEnd }
        guard let str = String(data: data[offset..<(offset + count)], encoding: .utf8) else {
            throw MessagePackError.invalidUTF8
        }
        offset += count
        return .string(str)
    }

    private static func decodeBinary(countBytes: Int, from data: Data, offset: inout Int) throws -> MessagePackValue {
        let count: Int
        switch countBytes {
        case 1: count = Int(try readUInt8(from: data, offset: &offset))
        case 2: count = Int(try readUInt16(from: data, offset: &offset))
        case 4: count = Int(try readUInt32(from: data, offset: &offset))
        default: throw MessagePackError.unsupportedType(0)
        }
        guard offset + count <= data.count else { throw MessagePackError.unexpectedEnd }
        let bin = Data(data[offset..<(offset + count)])
        offset += count
        return .binary(bin)
    }

    private static func decodeArray(count: Int, from data: Data, offset: inout Int) throws -> MessagePackValue {
        var arr: [MessagePackValue] = []
        arr.reserveCapacity(count)
        for _ in 0..<count {
            arr.append(try decodeValue(from: data, offset: &offset))
        }
        return .array(arr)
    }

    private static func decodeMap(count: Int, from data: Data, offset: inout Int) throws -> MessagePackValue {
        var pairs: [(MessagePackValue, MessagePackValue)] = []
        pairs.reserveCapacity(count)
        for _ in 0..<count {
            let key = try decodeValue(from: data, offset: &offset)
            let val = try decodeValue(from: data, offset: &offset)
            pairs.append((key, val))
        }
        return .map(pairs)
    }
}

// MARK: - Errors

public enum MessagePackError: Error, LocalizedError {
    case unexpectedEnd
    case unsupportedType(UInt8)
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .unexpectedEnd: return "Unexpected end of MessagePack data"
        case .unsupportedType(let b): return "Unsupported MessagePack type: 0x\(String(format: "%02X", b))"
        case .invalidUTF8: return "Invalid UTF-8 in MessagePack string"
        }
    }
}
