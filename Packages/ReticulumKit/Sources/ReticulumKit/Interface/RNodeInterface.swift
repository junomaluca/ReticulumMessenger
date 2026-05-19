// SPDX-License-Identifier: MIT
// ReticulumKit — RNodeInterface.swift
// BLE interface for communicating with RNode LoRa transceivers.
// Uses CoreBluetooth to connect to RNode via Nordic UART Service (NUS).

import Foundation
import CoreBluetooth

/// BLE-connected RNode LoRa transceiver interface.
/// Discovers, connects to, and communicates with RNode hardware
/// using the Nordic UART Service over Bluetooth Low Energy.
public final class RNodeInterface: NSObject, RNSInterface, @unchecked Sendable {

    // MARK: - BLE UUIDs (Nordic UART Service)

    private static let nusServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let nusTXCharUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")  // Write
    private static let nusRXCharUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")  // Notify

    // MARK: - Detection

    private static let detectByte: UInt8 = 0x73

    // MARK: - RNSInterface Properties

    public let name: String
    public private(set) var status: RNSInterfaceStatus = .disconnected
    public weak var delegate: RNSInterfaceDelegate?
    public private(set) var bytesSent: UInt64 = 0
    public private(set) var bytesReceived: UInt64 = 0
    public var interfaceType: String { "RNode (BLE)" }
    public var isOnline: Bool {
        if case .connected = status { return true }
        return false
    }

    // MARK: - RNode State

    /// Current radio configuration.
    public private(set) var config: RNodeConfig
    /// Firmware version string.
    public private(set) var firmwareVersion: String?
    /// Current RSSI of last received packet.
    public private(set) var lastRSSI: Int?
    /// Current SNR of last received packet.
    public private(set) var lastSNR: Float?
    /// Battery level (0-100, nil if not available).
    public private(set) var batteryLevel: UInt8?
    /// Whether the radio is currently transmitting/receiving.
    public private(set) var radioOnline = false
    /// Device platform identifier.
    public private(set) var platform: UInt8?

    // MARK: - BLE State

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?

    /// Target peripheral identifier (for reconnection).
    private var targetPeripheralId: UUID?

    /// KISS deframer for incoming data.
    private let deframer = KISSProtocol.Deframer()

    /// Connection continuation for async connect.
    private var connectContinuation: CheckedContinuation<Void, Error>?

    /// Whether auto-reconnect is enabled.
    private var shouldReconnect = true

    /// BLE write queue to handle MTU chunking.
    private var writeQueue: [Data] = []
    private var isWriting = false

    /// Callback for RNode info updates (RSSI, SNR, battery, etc.).
    public var infoCallback: (() -> Void)?

    /// Discovered RNode devices during scanning.
    public private(set) var discoveredDevices: [DiscoveredRNode] = []
    /// Callback when new devices are discovered.
    public var discoveryCallback: ((DiscoveredRNode) -> Void)?

    // MARK: - Types

    public struct DiscoveredRNode: Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let rssi: Int
    }

    // MARK: - Initialization

    /// Create an RNode interface.
    /// - Parameters:
    ///   - name: Display name for this interface.
    ///   - config: Initial radio configuration.
    ///   - peripheralId: UUID of a specific peripheral to connect to (for reconnection).
    public init(
        name: String = "RNode",
        config: RNodeConfig = .balanced,
        peripheralId: UUID? = nil
    ) {
        self.name = name
        self.config = config
        self.targetPeripheralId = peripheralId
        super.init()
    }

    // MARK: - Scanning

    /// Start scanning for RNode devices.
    public func startScanning() {
        discoveredDevices = []
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: .global(qos: .utility))
        } else if centralManager?.state == .poweredOn {
            centralManager?.scanForPeripherals(
                withServices: [Self.nusServiceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    /// Stop scanning.
    public func stopScanning() {
        centralManager?.stopScan()
    }

    // MARK: - RNSInterface

    public func connect() async throws {
        shouldReconnect = true

        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: .global(qos: .utility))
        }

        try await withCheckedThrowingContinuation { continuation in
            self.connectContinuation = continuation
            self.status = .connecting

            // If we have a target peripheral, wait for BLE powered on then connect
            // Otherwise, scan and connect to the first RNode found
            if centralManager?.state == .poweredOn {
                beginConnection()
            }
            // If not powered on yet, centralManagerDidUpdateState will trigger connection
        }
    }

    public func disconnect() async {
        shouldReconnect = false
        stopScanning()

        if let peripheral = peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }

        status = .disconnected
        radioOnline = false
        peripheral = nil
        txCharacteristic = nil
        rxCharacteristic = nil
    }

    public func send(_ data: Data) async throws {
        guard isOnline, let characteristic = txCharacteristic, let peripheral = peripheral else {
            throw RNodeError.notConnected
        }

        let kissFrame = KISSProtocol.frame(data: data)
        try await writeData(kissFrame, to: characteristic, on: peripheral)
        bytesSent += UInt64(data.count)
    }

    /// Radio statistics snapshot.
    public struct RadioStats {
        public var rssi: Int?
        public var snr: Float?
        public var battery: UInt8?
        public var online: Bool
        public var firmwareVersion: String?
    }

    /// Get current radio statistics.
    public var radioStats: RadioStats {
        RadioStats(
            rssi: lastRSSI,
            snr: lastSNR,
            battery: batteryLevel,
            online: radioOnline,
            firmwareVersion: firmwareVersion
        )
    }

    /// Connect to a specific device by UUID.
    public func connect(deviceId: UUID) async throws {
        targetPeripheralId = deviceId
        try await connect()
    }

    /// Apply a new configuration (convenience wrapper).
    public func configure(_ newConfig: RNodeConfig) async {
        try? await applyConfig(newConfig)
    }

    // MARK: - RNode Configuration

    /// Apply radio configuration to the connected RNode.
    public func applyConfig(_ newConfig: RNodeConfig) async throws {
        guard isOnline else { throw RNodeError.notConnected }
        config = newConfig

        try await sendCommand(.frequency, data: RNodeCommand.encode(config.frequency))
        try await sendCommand(.bandwidth, data: RNodeCommand.encode(config.bandwidth))
        try await sendCommand(.spreadingFactor, data: Data([config.spreadingFactor]))
        try await sendCommand(.codingRate, data: Data([config.codingRate]))
        try await sendCommand(.txPower, data: Data([config.txPower]))
    }

    /// Enable or disable the radio.
    public func setRadioState(_ enabled: Bool) async throws {
        guard isOnline else { throw RNodeError.notConnected }
        try await sendCommand(.radioState, data: Data([enabled ? 0x01 : 0x00]))
        radioOnline = enabled
    }

    /// Request device info (firmware version, battery, etc.).
    public func requestDeviceInfo() async throws {
        guard isOnline else { throw RNodeError.notConnected }
        try await sendCommand(.detect, data: Data([Self.detectByte]))
        try await sendCommand(.fwVersion, data: Data())
        try await sendCommand(.battery, data: Data())
        try await sendCommand(.platform, data: Data())
    }

    // MARK: - Private: Command Sending

    private func sendCommand(_ command: RNodeCommand, data: Data) async throws {
        guard let characteristic = txCharacteristic, let peripheral = peripheral else {
            throw RNodeError.notConnected
        }
        let frame = KISSProtocol.frame(data: data, command: command.rawValue)
        try await writeData(frame, to: characteristic, on: peripheral)
    }

    private func writeData(_ data: Data, to characteristic: CBCharacteristic, on peripheral: CBPeripheral) async throws {
        // BLE has MTU limits — chunk if needed
        let mtu = peripheral.maximumWriteValueLength(for: .withResponse)
        let chunkSize = max(mtu, 20)

        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                peripheral.writeValue(Data(chunk), for: characteristic, type: .withResponse)
                // Note: In production, use peripheral delegate didWriteValue callback
                // For simplicity, we resume immediately
                continuation.resume()
            }
            offset = end
        }
    }

    // MARK: - Private: Connection

    private func beginConnection() {
        if let targetId = targetPeripheralId,
           let peripherals = centralManager?.retrievePeripherals(withIdentifiers: [targetId]).first {
            // Reconnect to known device
            self.peripheral = peripherals
            peripherals.delegate = self
            centralManager?.connect(peripherals, options: nil)
        } else {
            // Scan for RNode devices
            centralManager?.scanForPeripherals(
                withServices: [Self.nusServiceUUID],
                options: nil
            )
        }
    }

    // MARK: - Private: Incoming Data

    private func processIncomingFrames(_ frames: [KISSProtocol.Deframer.Frame]) {
        for frame in frames {
            switch frame.command {
            case RNodeCommand.data.rawValue:
                // Data packet from radio
                bytesReceived += UInt64(frame.data.count)
                delegate?.interface(self, didReceivePacket: frame.data)

            case RNodeCommand.statRSSI.rawValue:
                if let val = frame.data.first {
                    lastRSSI = Int(Int8(bitPattern: val))
                    infoCallback?()
                }

            case RNodeCommand.statSNR.rawValue:
                if let val = frame.data.first {
                    lastSNR = Float(Int8(bitPattern: val)) / 4.0
                    infoCallback?()
                }

            case RNodeCommand.battery.rawValue:
                if frame.data.count >= 2 {
                    batteryLevel = frame.data[1]
                    infoCallback?()
                }

            case RNodeCommand.fwVersion.rawValue:
                if frame.data.count >= 2 {
                    let major = frame.data[0]
                    let minor = frame.data[1]
                    firmwareVersion = "\(major).\(minor)"
                    infoCallback?()
                }

            case RNodeCommand.platform.rawValue:
                if let val = frame.data.first {
                    platform = val
                    infoCallback?()
                }

            case RNodeCommand.ready.rawValue:
                radioOnline = true
                infoCallback?()

            case RNodeCommand.detect.rawValue:
                // Detection response — RNode is present
                break

            case RNodeCommand.error.rawValue:
                let errorMsg = String(data: frame.data, encoding: .utf8) ?? "Unknown RNode error"
                status = .error(errorMsg)

            default:
                break
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension RNodeInterface: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if status == .connecting {
                beginConnection()
            }
        case .poweredOff:
            status = .error("Bluetooth is off")
            connectContinuation?.resume(throwing: RNodeError.bluetoothOff)
            connectContinuation = nil
        case .unauthorized:
            status = .error("Bluetooth not authorized")
            connectContinuation?.resume(throwing: RNodeError.bluetoothUnauthorized)
            connectContinuation = nil
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let device = DiscoveredRNode(
            id: peripheral.identifier,
            name: peripheral.name ?? "RNode",
            rssi: RSSI.intValue
        )

        if !discoveredDevices.contains(where: { $0.id == device.id }) {
            discoveredDevices.append(device)
            discoveryCallback?(device)
        }

        // If connecting and no specific target, connect to first found
        if status == .connecting && targetPeripheralId == nil {
            central.stopScan()
            self.peripheral = peripheral
            self.targetPeripheralId = peripheral.identifier
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.nusServiceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = .error(error?.localizedDescription ?? "Connection failed")
        connectContinuation?.resume(throwing: error ?? RNodeError.connectionFailed)
        connectContinuation = nil
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let wasOnline = isOnline
        status = .disconnected
        radioOnline = false
        txCharacteristic = nil
        rxCharacteristic = nil
        deframer.reset()

        if wasOnline {
            delegate?.interfaceDidDisconnect(self, error: error)
        }

        // Auto-reconnect
        if shouldReconnect {
            DispatchQueue.global().asyncAfter(deadline: .now() + RNS.reconnectDelay) { [weak self] in
                guard let self = self, self.shouldReconnect else { return }
                self.status = .connecting
                self.peripheral = peripheral
                peripheral.delegate = self
                central.connect(peripheral, options: nil)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension RNodeInterface: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.nusServiceUUID }) else {
            connectContinuation?.resume(throwing: RNodeError.serviceNotFound)
            connectContinuation = nil
            return
        }
        peripheral.discoverCharacteristics(
            [Self.nusTXCharUUID, Self.nusRXCharUUID],
            for: service
        )
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }

        for char in characteristics {
            if char.uuid == Self.nusTXCharUUID {
                txCharacteristic = char
            } else if char.uuid == Self.nusRXCharUUID {
                rxCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
            }
        }

        if txCharacteristic != nil && rxCharacteristic != nil {
            status = .connected
            delegate?.interfaceDidConnect(self)

            // Configure the radio
            Task {
                try? await applyConfig(config)
                try? await setRadioState(true)
                try? await requestDeviceInfo()
            }

            connectContinuation?.resume()
            connectContinuation = nil
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.nusRXCharUUID, let data = characteristic.value else { return }
        let frames = deframer.feed(data)
        if !frames.isEmpty {
            processIncomingFrames(frames)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Handle write completion if needed
    }
}

// MARK: - Errors

public enum RNodeError: Error, LocalizedError {
    case notConnected
    case bluetoothOff
    case bluetoothUnauthorized
    case serviceNotFound
    case connectionFailed
    case configurationFailed
    case radioError(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "RNode is not connected"
        case .bluetoothOff: return "Bluetooth is turned off"
        case .bluetoothUnauthorized: return "Bluetooth access not authorized"
        case .serviceNotFound: return "RNode UART service not found"
        case .connectionFailed: return "Failed to connect to RNode"
        case .configurationFailed: return "Failed to configure RNode radio"
        case .radioError(let msg): return "Radio error: \(msg)"
        }
    }
}
