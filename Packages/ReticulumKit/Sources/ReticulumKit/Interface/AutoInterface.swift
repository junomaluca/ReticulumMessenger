// SPDX-License-Identifier: MIT
// ReticulumKit — AutoInterface.swift
// Automatic multicast peer discovery interface for local mesh networking.
// Learned from Columba-iOS (NWConnectionGroup multicast) and runcore
// (virtual interface filtering for iOS).

import Foundation
import Network

/// An automatic multicast interface that discovers peers on the local network
/// using IPv6 link-local multicast. This is the iOS equivalent of Reticulum's
/// AutoInterface, using Apple's Network framework instead of raw sockets.
///
/// Key iOS considerations (from runcore/Columba research):
/// - Uses NWConnectionGroup for multicast (iOS-compatible, no raw sockets needed)
/// - Filters out virtual interfaces (utun*, awdl0*, bridge*) that iOS creates
/// - Supports both the default Reticulum multicast group and discovery ports
public final class AutoInterface: @unchecked Sendable {

    // MARK: - Constants

    /// Default Reticulum AutoInterface multicast group (IPv6 link-local all-nodes).
    public static let defaultMulticastGroup = "ff02::1"

    /// Default Reticulum AutoInterface discovery port.
    public static let defaultDiscoveryPort: UInt16 = 29716

    /// Data port for actual packet exchange.
    public static let defaultDataPort: UInt16 = 42671

    /// iOS virtual interfaces to ignore (from runcore research).
    /// These are iOS-internal interfaces that should never be used for mesh.
    private static let blockedInterfacePrefixes = [
        "utun",    // VPN/Network Extension tunnels
        "awdl0",   // Apple Wireless Direct Link (AirDrop, etc.)
        "bridge",  // Bridge interfaces
        "llw",     // Low Latency WLAN (AirDrop)
        "ipsec",   // IPSec tunnels
        "lo",      // Loopback
        "gif",     // Generic tunnel
        "stf",     // 6to4 tunnel
        "anpi",    // Apple Network Proxy Interface
    ]

    /// Allowed physical interface prefixes (from runcore: allowlist approach).
    private static let allowedInterfacePrefixes = [
        "en",      // Ethernet/WiFi
        "pdp_ip",  // Cellular data
    ]

    // MARK: - Properties

    public let name: String
    public private(set) var status: RNSInterfaceStatus = .disconnected
    public weak var delegate: RNSInterfaceDelegate?
    public private(set) var bytesSent: UInt64 = 0
    public private(set) var bytesReceived: UInt64 = 0
    public var interfaceType: String { "Auto" }

    public var isOnline: Bool {
        if case .connected = status { return true }
        return false
    }

    private let multicastGroup: String
    private let discoveryPort: UInt16
    private let dataPort: UInt16
    private var connectionGroup: NWConnectionGroup?
    private var dataListener: NWListener?
    private let queue = DispatchQueue(label: "com.reticulumkit.auto", qos: .utility)

    /// Known peer endpoints discovered via multicast.
    private var discoveredPeers: Set<String> = []

    // MARK: - Initialization

    public init(
        name: String = "AutoInterface",
        multicastGroup: String = defaultMulticastGroup,
        discoveryPort: UInt16 = defaultDiscoveryPort,
        dataPort: UInt16 = defaultDataPort
    ) {
        self.name = name
        self.multicastGroup = multicastGroup
        self.discoveryPort = discoveryPort
        self.dataPort = dataPort
    }

    // MARK: - Interface Filtering

    /// Check if a network interface name should be used for multicast.
    /// From runcore: iOS creates many virtual interfaces that must be filtered out.
    static func shouldUseInterface(named name: String) -> Bool {
        // Check against blocklist
        for prefix in blockedInterfacePrefixes {
            if name.hasPrefix(prefix) { return false }
        }
        // Check against allowlist
        for prefix in allowedInterfacePrefixes {
            if name.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// Get the list of physical network interfaces suitable for multicast.
    public static func availableInterfaces() -> [String] {
        var interfaces: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }

        var seen = Set<String>()
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            if !seen.contains(name) && shouldUseInterface(named: name) {
                seen.insert(name)
                interfaces.append(name)
            }
        }
        freeifaddrs(ifaddr)
        return interfaces
    }
}

// MARK: - RNSInterface

extension AutoInterface: RNSInterface {

    public func connect() async throws {
        // Set up multicast group for peer discovery
        guard let port = NWEndpoint.Port(rawValue: discoveryPort) else {
            throw AutoInterfaceError.invalidPort
        }

        let multicast = try NWMulticastGroup(
            for: [.hostPort(host: NWEndpoint.Host(multicastGroup), port: port)]
        )

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let group = NWConnectionGroup(with: multicast, using: params)
        self.connectionGroup = group

        group.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.status = .connected
                self.delegate?.interfaceDidConnect(self)
            case .failed(let error):
                self.status = .error(error.localizedDescription)
                self.delegate?.interfaceDidDisconnect(self, error: error)
            case .cancelled:
                self.status = .disconnected
            default:
                break
            }
        }

        // Receive multicast messages (peer discovery + data)
        group.setReceiveHandler(maximumMessageSize: Int(RNS.mtu) + 100, rejectOversizedMessages: true) {
            [weak self] message, content, isComplete in
            guard let self = self, let data = content, !data.isEmpty else { return }
            self.bytesReceived += UInt64(data.count)
            self.delegate?.interface(self, didReceivePacket: data)

            // Track the peer endpoint for direct messaging
            if let remote = message.remoteEndpoint, case .hostPort(let host, _) = remote {
                let peerKey = "\(host)"
                self.discoveredPeers.insert(peerKey)
            }
        }

        group.start(queue: queue)

        // Also set up a UDP listener on the data port for direct peer traffic
        if let listenPort = NWEndpoint.Port(rawValue: dataPort) {
            let listenerParams = NWParameters.udp
            listenerParams.allowLocalEndpointReuse = true
            if let listener = try? NWListener(using: listenerParams, on: listenPort) {
                self.dataListener = listener
                listener.newConnectionHandler = { [weak self] conn in
                    self?.handleIncomingConnection(conn)
                }
                listener.start(queue: queue)
            }
        }
    }

    public func disconnect() async {
        connectionGroup?.cancel()
        connectionGroup = nil
        dataListener?.cancel()
        dataListener = nil
        discoveredPeers.removeAll()
        status = .disconnected
    }

    public func send(_ data: Data) async throws {
        guard let group = connectionGroup, isOnline else {
            throw AutoInterfaceError.notConnected
        }

        // Broadcast via multicast group
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.send(content: data) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    self.bytesSent += UInt64(data.count)
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Private

    private func handleIncomingConnection(_ conn: NWConnection) {
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

// MARK: - Errors

public enum AutoInterfaceError: Error, LocalizedError {
    case notConnected
    case invalidPort
    case multicastSetupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "AutoInterface not connected"
        case .invalidPort: return "Invalid port configuration"
        case .multicastSetupFailed(let msg): return "Multicast setup failed: \(msg)"
        }
    }
}
