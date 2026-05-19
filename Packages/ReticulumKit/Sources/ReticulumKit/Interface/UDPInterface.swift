// SPDX-License-Identifier: MIT
// ReticulumKit — UDPInterface.swift
// UDP interface for Reticulum communication.

import Foundation
import Network

/// A UDP interface for broadcasting and receiving Reticulum packets.
/// Supports both unicast (to a specific host) and broadcast modes.
public final class UDPInterface: @unchecked Sendable {

    // MARK: - Properties

    public let name: String
    public private(set) var status: RNSInterfaceStatus = .disconnected
    public weak var delegate: RNSInterfaceDelegate?
    public private(set) var bytesSent: UInt64 = 0
    public private(set) var bytesReceived: UInt64 = 0
    public var interfaceType: String { "UDP" }

    public var isOnline: Bool {
        if case .connected = status { return true }
        return false
    }

    private let host: String?
    private let port: UInt16
    private let listenPort: UInt16
    private var connection: NWConnection?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.reticulumkit.udp", qos: .utility)

    // MARK: - Initialization

    /// Create a UDP interface.
    /// - Parameters:
    ///   - name: Display name.
    ///   - host: Remote host for sending (nil for receive-only/broadcast).
    ///   - port: Remote port to send to.
    ///   - listenPort: Local port to listen on.
    public init(name: String, host: String? = nil, port: UInt16 = RNS.defaultTCPPort, listenPort: UInt16 = 0) {
        self.name = name
        self.host = host
        self.port = port
        self.listenPort = listenPort > 0 ? listenPort : port
    }
}

// MARK: - RNSInterface

extension UDPInterface: RNSInterface {

    public func connect() async throws {
        // Set up listener
        let params = NWParameters.udp
        if let listenNWPort = NWEndpoint.Port(rawValue: listenPort),
           let listener = try? NWListener(using: params, on: listenNWPort) {
            self.listener = listener
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleIncoming(conn)
            }
            listener.start(queue: queue)
        }

        // Set up sender if host specified
        if let host = host {
            guard let sendPort = NWEndpoint.Port(rawValue: port) else {
                throw UDPInterfaceError.notConnected
            }
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: sendPort
            )
            let conn = NWConnection(to: endpoint, using: .udp)
            self.connection = conn

            conn.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.status = .connected
                    self.delegate?.interfaceDidConnect(self)
                case .failed(let error):
                    self.status = .error(error.localizedDescription)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        } else {
            status = .connected
        }
    }

    public func disconnect() async {
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        status = .disconnected
    }

    public func send(_ data: Data) async throws {
        guard let connection = connection else {
            throw UDPInterfaceError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    self.bytesSent += UInt64(data.count)
                    continuation.resume()
                }
            })
        }
    }

    private func handleIncoming(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveLoop(conn)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] content, _, _, error in
            guard let self = self else { return }
            if let data = content, !data.isEmpty {
                self.bytesReceived += UInt64(data.count)
                self.delegate?.interface(self, didReceivePacket: data)
            }
            if error == nil {
                self.receiveLoop(conn)
            }
        }
    }
}

public enum UDPInterfaceError: Error, LocalizedError {
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "UDP interface not connected"
        }
    }
}
