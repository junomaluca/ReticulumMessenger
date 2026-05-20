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

    /// Timestamp of last successful data exchange — used to detect stale iOS sockets.
    public private(set) var lastActivityTime: Date = Date()

    /// Whether a force-reconnect is currently in progress.
    private var isForceReconnecting = false

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
                    self.lastActivityTime = Date()
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - iOS Resilience

    /// Force-reconnect this interface by tearing down the existing socket and
    /// re-establishing. Critical on iOS where sockets go half-dead after
    /// app suspend/resume cycles — the connection appears ready but cannot
    /// actually transmit data. Learned from runcore project.
    public func forceReconnect() async throws {
        guard !isForceReconnecting else { return }
        isForceReconnecting = true
        defer { isForceReconnecting = false }

        // Tear down existing connection without disabling auto-reconnect
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
        status = .disconnected

        // Brief pause to let the old socket fully release (runcore uses 400ms)
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Re-establish
        reconnectDelay = RNS.reconnectDelay
        receiveBuffer = Data()
        inFrame = false
        escapeNext = false
        try await establishConnection()
    }

    /// Check if this connection appears stale (no data exchanged recently).
    /// iOS can leave sockets in a half-dead state where `isOnline` is true
    /// but no data flows.
    public var isStale: Bool {
        guard isOnline else { return false }
        return Date().timeIntervalSince(lastActivityTime) > 30.0
    }

    // MARK: - Connection Management

    private func establishConnection() async throws {
        status = .connecting

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TCPInterfaceError.connectionFailed("Invalid port: \(port)")
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort
        )

        let params = NWParameters.tcp

        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        return try await withCheckedThrowingContinuation { continuation in
            // Protected with os_unfair_lock to safely guard one-shot continuation
            // across NWConnection's concurrent state callbacks.
            let resumeOnce = ResumeOnce(continuation: continuation)

            conn.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.status = .connected
                    self.reconnectDelay = RNS.reconnectDelay
                    self.receiveBuffer = Data()
                    self.inFrame = false
                    self.escapeNext = false
                    self.lastActivityTime = Date()
                    self.delegate?.interfaceDidConnect(self)
                    self.startReceiving()
                    resumeOnce.resume()

                case .failed(let error):
                    self.status = .error(error.localizedDescription)
                    self.delegate?.interfaceDidDisconnect(self, error: error)
                    if !resumeOnce.resume(throwing: error) {
                        self.scheduleReconnect()
                    }

                case .waiting(let error):
                    self.status = .error("Waiting: \(error.localizedDescription)")
                    // Resume the continuation so callers aren't stuck forever.
                    // The interface will keep retrying via scheduleReconnect.
                    if !resumeOnce.resume(throwing: error) {
                        self.scheduleReconnect()
                    }

                case .cancelled:
                    self.status = .disconnected
                    resumeOnce.resume(throwing: TCPInterfaceError.connectionFailed("Connection cancelled"))

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
                self.lastActivityTime = Date()
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

// MARK: - ResumeOnce

/// Thread-safe one-shot continuation wrapper.
/// Ensures a `CheckedContinuation` is resumed at most once, even when
/// `NWConnection.stateUpdateHandler` fires from multiple threads.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    /// Resume with success. Returns `true` if this was the first call.
    @discardableResult
    func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let c = continuation else { return false }
        continuation = nil
        c.resume()
        return true
    }

    /// Resume with an error. Returns `true` if this was the first call.
    @discardableResult
    func resume(throwing error: Error) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let c = continuation else { return false }
        continuation = nil
        c.resume(throwing: error)
        return true
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
