// SPDX-License-Identifier: MIT
// ReticulumKit — KISSProtocol.swift
// KISS (Keep It Simple, Stupid) protocol framing for serial/BLE interfaces.
// Used by RNode and other serial-connected Reticulum interfaces.

import Foundation

/// KISS protocol framing and deframing.
/// KISS uses 0xC0 (FEND) as frame delimiters and 0xDB (FESC) for byte stuffing.
public enum KISSProtocol {

    // MARK: - Constants

    /// Frame End delimiter.
    public static let FEND: UInt8 = 0xC0
    /// Frame Escape byte.
    public static let FESC: UInt8 = 0xDB
    /// Transposed Frame End (after FESC, represents FEND).
    public static let TFEND: UInt8 = 0xDC
    /// Transposed Frame Escape (after FESC, represents FESC).
    public static let TFESC: UInt8 = 0xDD

    // MARK: - KISS Command Types

    public static let CMD_DATA: UInt8 = 0x00
    public static let CMD_TXDELAY: UInt8 = 0x01
    public static let CMD_PERSISTENCE: UInt8 = 0x02
    public static let CMD_SLOTTIME: UInt8 = 0x03
    public static let CMD_TXTAIL: UInt8 = 0x04
    public static let CMD_FULLDUPLEX: UInt8 = 0x05
    public static let CMD_RETURN: UInt8 = 0xFF

    // MARK: - Framing

    /// Frame a data payload into a KISS frame.
    /// Format: FEND + command + escaped_data + FEND
    public static func frame(data: Data, command: UInt8 = CMD_DATA, port: UInt8 = 0) -> Data {
        var framed = Data()
        framed.append(FEND)
        framed.append((port << 4) | command)

        for byte in data {
            switch byte {
            case FEND:
                framed.append(FESC)
                framed.append(TFEND)
            case FESC:
                framed.append(FESC)
                framed.append(TFESC)
            default:
                framed.append(byte)
            }
        }

        framed.append(FEND)
        return framed
    }

    /// Frame a raw command (no data payload).
    public static func frameCommand(_ command: UInt8, data: Data = Data()) -> Data {
        frame(data: data, command: command)
    }

    // MARK: - Deframing

    /// Stateful KISS deframer that accumulates bytes and emits complete frames.
    public final class Deframer {

        /// A decoded KISS frame.
        public struct Frame {
            public let command: UInt8
            public let port: UInt8
            public let data: Data
        }

        private var buffer = Data()
        private var inFrame = false
        private var escapeNext = false

        public init() {}

        /// Feed raw bytes into the deframer.
        /// Returns any complete frames found.
        public func feed(_ incoming: Data) -> [Frame] {
            var frames: [Frame] = []

            for byte in incoming {
                if byte == FEND {
                    if inFrame && buffer.count > 0 {
                        // End of frame — decode it
                        if let frame = decodeFrame(buffer) {
                            frames.append(frame)
                        }
                    }
                    // Start new frame
                    buffer = Data()
                    inFrame = true
                    escapeNext = false
                } else if inFrame {
                    if escapeNext {
                        switch byte {
                        case TFEND:
                            buffer.append(FEND)
                        case TFESC:
                            buffer.append(FESC)
                        default:
                            // Invalid escape sequence — append as-is
                            buffer.append(byte)
                        }
                        escapeNext = false
                    } else if byte == FESC {
                        escapeNext = true
                    } else {
                        buffer.append(byte)
                    }
                }
            }

            return frames
        }

        /// Reset the deframer state.
        public func reset() {
            buffer = Data()
            inFrame = false
            escapeNext = false
        }

        private func decodeFrame(_ data: Data) -> Frame? {
            guard !data.isEmpty else { return nil }
            let cmdByte = data[0]
            let command = cmdByte & 0x0F
            let port = (cmdByte >> 4) & 0x0F
            let payload = data.count > 1 ? Data(data[1...]) : Data()
            return Frame(command: command, port: port, data: payload)
        }
    }
}

// MARK: - RNode Commands

/// Extended KISS command set used by RNode hardware.
/// These commands configure the LoRa radio parameters.
public enum RNodeCommand: UInt8 {
    // Radio configuration
    case frequency     = 0x01
    case bandwidth     = 0x02
    case txPower       = 0x03
    case spreadingFactor = 0x04
    case codingRate    = 0x05
    case radioState    = 0x06
    case radioLock     = 0x07
    case stAirtimeLimit = 0x08
    case ltAirtimeLimit = 0x09

    // Device info
    case detect        = 0x10
    case leave         = 0x11
    case fwVersion     = 0x12
    case romRead       = 0x13
    case romWrite      = 0x14
    case romData       = 0x15
    case battery       = 0x16
    case btCtrl        = 0x17
    case btName        = 0x18

    // Statistics
    case statRX        = 0x21
    case statTX        = 0x22
    case statRSSI      = 0x23
    case statSNR       = 0x24
    case statPhyLock   = 0x25
    case statPhySpeed  = 0x26
    case statChannelActivity = 0x27
    case statAirtime   = 0x28

    // Platform
    case mcuPort       = 0x40
    case platform      = 0x46
    case mcu           = 0x47
    case error         = 0x90
    case ready         = 0x42
    case reset         = 0x55
    case romDone       = 0x93

    // Data
    case data          = 0x00

    /// Encode a UInt32 value as 4 big-endian bytes for RNode commands.
    public static func encode(_ value: UInt32) -> Data {
        var data = Data(count: 4)
        data[0] = UInt8((value >> 24) & 0xFF)
        data[1] = UInt8((value >> 16) & 0xFF)
        data[2] = UInt8((value >> 8) & 0xFF)
        data[3] = UInt8(value & 0xFF)
        return data
    }

    /// Decode 4 big-endian bytes to UInt32.
    public static func decodeUInt32(_ data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return UInt32(data[0]) << 24 | UInt32(data[1]) << 16 |
               UInt32(data[2]) << 8 | UInt32(data[3])
    }
}

/// Configuration parameters for an RNode device.
public struct RNodeConfig: Codable, Sendable {
    /// Radio frequency in Hz (e.g., 868_000_000 for 868 MHz).
    public var frequency: UInt32

    /// Bandwidth in Hz (e.g., 125_000 for 125 kHz).
    public var bandwidth: UInt32

    /// Spreading factor (7-12).
    public var spreadingFactor: UInt8

    /// Coding rate (5-8, representing 4/5 to 4/8).
    public var codingRate: UInt8

    /// Transmit power in dBm.
    public var txPower: UInt8

    public init(
        frequency: UInt32 = 868_000_000,
        bandwidth: UInt32 = 125_000,
        spreadingFactor: UInt8 = 7,
        codingRate: UInt8 = 5,
        txPower: UInt8 = 17
    ) {
        self.frequency = frequency
        self.bandwidth = bandwidth
        self.spreadingFactor = spreadingFactor
        self.codingRate = codingRate
        self.txPower = txPower
    }

    /// Common presets for LoRa configurations.
    public static let longRange = RNodeConfig(
        frequency: 868_000_000,
        bandwidth: 125_000,
        spreadingFactor: 12,
        codingRate: 8,
        txPower: 22
    )

    public static let balanced = RNodeConfig(
        frequency: 868_000_000,
        bandwidth: 125_000,
        spreadingFactor: 9,
        codingRate: 5,
        txPower: 17
    )

    public static let fast = RNodeConfig(
        frequency: 868_000_000,
        bandwidth: 250_000,
        spreadingFactor: 7,
        codingRate: 5,
        txPower: 17
    )

    /// Human-readable bandwidth string.
    public var bandwidthString: String {
        if bandwidth >= 1_000_000 {
            return String(format: "%.1f MHz", Double(bandwidth) / 1_000_000)
        }
        return String(format: "%.1f kHz", Double(bandwidth) / 1_000)
    }

    /// Human-readable frequency string.
    public var frequencyString: String {
        String(format: "%.3f MHz", Double(frequency) / 1_000_000)
    }
}
