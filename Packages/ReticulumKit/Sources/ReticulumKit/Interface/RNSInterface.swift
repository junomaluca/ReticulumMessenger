// SPDX-License-Identifier: MIT
// ReticulumKit — RNSInterface.swift
// Protocol definition for Reticulum network interfaces.

import Foundation

/// Delegate protocol for receiving interface events.
public protocol RNSInterfaceDelegate: AnyObject, Sendable {
    /// Called when a packet is received on an interface.
    func interface(_ interface: any RNSInterface, didReceivePacket data: Data)
    /// Called when the interface connects.
    func interfaceDidConnect(_ interface: any RNSInterface)
    /// Called when the interface disconnects.
    func interfaceDidDisconnect(_ interface: any RNSInterface, error: Error?)
}

/// Status of a network interface.
public enum RNSInterfaceStatus: Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

/// Protocol that all Reticulum network interfaces must conform to.
/// Interfaces handle the actual sending and receiving of raw packet bytes
/// over a particular medium (TCP, UDP, serial, etc.).
public protocol RNSInterface: AnyObject, Sendable {

    /// Unique name for this interface.
    var name: String { get }

    /// Current connection status.
    var status: RNSInterfaceStatus { get }

    /// Whether this interface is currently online and able to send.
    var isOnline: Bool { get }

    /// Delegate for receiving events.
    var delegate: RNSInterfaceDelegate? { get set }

    /// Total bytes sent through this interface.
    var bytesSent: UInt64 { get }

    /// Total bytes received through this interface.
    var bytesReceived: UInt64 { get }

    /// Bring the interface online.
    func connect() async throws

    /// Take the interface offline.
    func disconnect() async

    /// Send raw packet bytes through this interface.
    /// The interface is responsible for any framing needed.
    func send(_ data: Data) async throws

    /// Interface type identifier for display.
    var interfaceType: String { get }
}

/// Configuration for a network interface.
public struct RNSInterfaceConfig: Codable, Sendable {
    public var name: String
    public var type: InterfaceType
    public var enabled: Bool
    public var host: String?
    public var port: UInt16?

    public enum InterfaceType: String, Codable, Sendable {
        case tcpClient = "TCPClientInterface"
        case tcpServer = "TCPServerInterface"
        case udp = "UDPInterface"
    }

    public init(
        name: String,
        type: InterfaceType,
        enabled: Bool = true,
        host: String? = nil,
        port: UInt16? = nil
    ) {
        self.name = name
        self.type = type
        self.enabled = enabled
        self.host = host
        self.port = port
    }
}
