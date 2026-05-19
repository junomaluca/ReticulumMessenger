// SPDX-License-Identifier: MIT
// ReticulumKit — TCPClientInterface.swift
// TCP client interface for connecting to Reticulum transport nodes.

import Foundation
import Network

/// A TCP client interface that connects to a remote Reticulum node.
/// Uses Apple's Network framework for modern, efficient networking.
///
/// The TCP framing protocol uses HDLC-like byte stuffing:
/// - Flag byte (0x7E) marks frame boundaries
/// - Escape byte (0x7D) precedes stuffed bytes
/// - Stuffed bytes are XOR'd with 0x20
public final class TCPClientInterface: RNSInterface, @unchecked Sendable {

    // MARK: - Constants

    private static let flagByte: UInt8 = 0x7E
    private static let escapeByte: UInt8 = 0x7D
    private static let escapeXOR: UInt8 = 0x20

    // MARK: - Properties

    public let name: String
    public private(set) var status: RNSInterfaceStatus = .disconnected
    public weak var delegate: RNSInterfaceDelegate?
    public private(set) var bytesSent: UInt64 = 0
    public private(set) var bytesReceived: UInt64 = 0
    public var interfaceType: String { "TCPClient" }

    public var isOnline: Bool {
        if case .connected = status { return true }
        return false
    }

    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.reticulumkit.tcp", qos: .utility)

    /// Buffer for accumulating incoming HDLC frames.
    private var receiveBuffer = Data()
    private var inFrame = false
    private var escapeNext = false

    /// Reconnection state.
    private var shouldReconnect = true
    private var reconnectDelay: TimeInterval = RNS.reconnectDelay
    private var reconnectTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Create a TCP client interface.
    /// - Parameters:
    ///   - name: Display name for this interface.
    ///   - host: Remote host to connect to.
    ///   - port: Remote port (default: 4242).
    public init(name: String, host: String, port: UInt16 = RNS.defaultTCPPort) {
        self.name = name
        self.host = host
        self.port = port
    }

    deinit {
        shouldReconnect = false
        reconnectTask?.cancel()
        connection?.cancel()
    }

    // MARK: - RNSInterface

    public func connect() async throws {
        shouldReconnect = true
        try await establishConnection()
    }

    public func disconnect() async {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
        status = .disconnected
    }

    public func send(_ data: Data) async throws {
        guard let connection = connection, isOnline else {
            throw TCPInterfaceError.notConnected
        }

        let framed = frame(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    self.bytesSent += UInt64(framed.count)
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Connection Management

    private func establishConnection() async throws {
        status = .connecting

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )

        let params = NWParameters.tcp
        params.requiredInterfaceType = .other  // Allow any network

        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false

            conn.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.status = .connected
                    self.reconnectDelay = RNS.reconnectDelay
                    self.receiveBuffer = Data()
                    self.inFrame = false
                    self.escapeNext = false
                    self.delegate?.interfaceDidConnect(self)
                    self.startReceiving()
                    if !resumed {
                        resumed = true
                        continuation.resume()
                    }

                case .failed(let error):
                    self.status = .error(error.localizedDescription)
                    self.delegate?.interfaceDidDisconnect(self, error: error)
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    } else {
                        self.scheduleReconnect()
                    }

                case .waiting(let error):
                    self.status = .error("Waiting: \(error.localizedDescription)")

                case .cancelled:
                    self.status = .disconnected

                default:
                    break
                }
            }

            conn.start(queue: queue)
        }
    }

    // MARK: - Receiving

    private func startReceiving() {
        guard let connection = connection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.bytesReceived += UInt64(data.count)
                self.processIncoming(data)
            }

            if isComplete {
                self.status = .disconnected
                self.delegate?.interfaceDidDisconnect(self, error: nil)
                self.scheduleReconnect()
            } else if let error = error {
                self.status = .error(error.localizedDescription)
                self.delegate?.interfaceDidDisconnect(self, error: error)
                self.scheduleReconnect()
            } else {
                // Continue receiving
                self.startReceiving()
            }
        }
    }

    // MARK: - HDLC Framing

    /// Process incoming bytes and extract complete HDLC frames.
    private func processIncoming(_ data: Data) {
        for byte in data {
            if byte == Self.flagByte {
                if inFrame && !receiveBuffer.isEmpty {
                    // End of frame — dispatch the packet
                    let packet = receiveBuffer
                    receiveBuffer = Data()
                    delegate?.interface(self, didReceivePacket: packet)
                }
                inFrame = true
                receiveBuffer = Data()
                escapeNext = false
            } else if inFrame {
                if escapeNext {
                    receiveBuffer.append(byte ^ Self.escapeXOR)
                    escapeNext = false
                } else if byte == Self.escapeByte {
                    escapeNext = true
                } else {
                    receiveBuffer.append(byte)
                }
            }
        }
    }

    /// Frame data using HDLC-like byte stuffing.
    private func frame(_ data: Data) -> Data {
        var framed = Data()
        framed.append(Self.flagByte)

        for byte in data {
            if byte == Self.flagByte || byte == Self.escapeByte {
                framed.append(Self.escapeByte)
                framed.append(byte ^ Self.escapeXOR)
            } else {
                framed.append(byte)
            }
        }

        framed.append(Self.flagByte)
        return framed
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        guard shouldReconnect else { return }

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self = self else { return }
            let delay = self.reconnectDelay

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            guard !Task.isCancelled, self.shouldReconnect else { return }

            // Exponential backoff
            self.reconnectDelay = min(
                self.reconnectDelay * 2,
                RNS.maxReconnectDelay
            )

            do {
                try await self.establishConnection()
            } catch {
                self.scheduleReconnect()
            }
        }
    }
}

// MARK: - Errors

public enum TCPInterfaceError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Interface is not connected"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        }
    }
}
