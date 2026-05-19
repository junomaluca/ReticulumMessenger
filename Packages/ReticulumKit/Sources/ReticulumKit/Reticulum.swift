// SPDX-License-Identifier: MIT
// ReticulumKit — Reticulum.swift
// Main coordinator for the Reticulum Network Stack.

import Foundation

/// The main Reticulum Network Stack coordinator.
/// Manages the lifecycle of interfaces, transport, identities, and provides
/// the primary API for applications to interact with the network.
public actor Reticulum {

    // MARK: - Properties

    /// The transport layer.
    public let transport: RNSTransport

    /// Identity storage manager.
    public let identityStorage: IdentityStorage

    /// The local identity for this node.
    public private(set) var localIdentity: RNSIdentity?

    /// Whether the stack is currently running.
    public private(set) var isRunning = false

    /// Configuration for this instance.
    private let config: ReticulumConfig

    /// Background maintenance task.
    private var maintenanceTask: Task<Void, Never>?

    /// Interface delegate bridge.
    private var interfaceBridge: InterfaceBridge?

    // MARK: - Initialization

    /// Create a new Reticulum instance.
    /// - Parameter config: Configuration options. Uses defaults if nil.
    public init(config: ReticulumConfig? = nil) {
        self.config = config ?? ReticulumConfig()
        self.transport = RNSTransport()
        self.identityStorage = IdentityStorage()
    }

    // MARK: - Lifecycle

    /// Start the Reticulum Network Stack.
    /// Loads or creates the local identity and connects configured interfaces.
    public func start() async throws {
        guard !isRunning else { return }

        // Load or create primary identity
        let identity = try await identityStorage.loadOrCreate()
        self.localIdentity = identity

        // Load known identities cache
        try? await identityStorage.loadKnownIdentities()

        // Create interface delegate bridge
        let bridge = InterfaceBridge(transport: transport)
        self.interfaceBridge = bridge

        // Set up configured interfaces
        for ifConfig in config.interfaces where ifConfig.enabled {
            if let interface = createInterface(from: ifConfig) {
                interface.delegate = bridge
                await transport.addInterface(interface)
                Task {
                    try? await interface.connect()
                }
            }
        }

        isRunning = true

        // Start maintenance loop
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
                await self?.performMaintenance()
            }
        }
    }

    /// Stop the Reticulum Network Stack.
    public func stop() async {
        guard isRunning else { return }

        maintenanceTask?.cancel()
        maintenanceTask = nil

        // Disconnect all interfaces
        for interface in await transport.getInterfaces() {
            await interface.disconnect()
        }

        // Save known identities
        try? await identityStorage.saveKnownIdentities()

        isRunning = false
    }

    // MARK: - Identity

    /// Get the local identity, creating one if needed.
    public func getLocalIdentity() async throws -> RNSIdentity {
        if let identity = localIdentity {
            return identity
        }
        let identity = try await identityStorage.loadOrCreate()
        localIdentity = identity
        return identity
    }

    // MARK: - Destinations

    /// Create and register a destination for the local identity.
    public func createDestination(
        appName: String,
        aspects: [String] = []
    ) async throws -> RNSDestination {
        let identity = try await getLocalIdentity()
        let destination = RNSDestination(
            identity: identity,
            type: .single,
            appName: appName,
            aspects: aspects
        )
        await transport.registerDestination(destination)
        return destination
    }

    // MARK: - Sending

    /// Send a packet to a destination.
    @discardableResult
    public func send(data: Data, to destination: RNSDestination) async throws -> RNSPacketReceipt? {
        let packet = RNSPacket.data(to: destination, data: data)
        return try await transport.sendPacket(packet)
    }

    /// Announce a destination to the network.
    public func announce(destination: RNSDestination, appData: Data? = nil) async throws {
        let announceData = try destination.announce(appData: appData)
        let packet = RNSPacket.announce(from: destination, data: announceData)
        _ = try await transport.sendPacket(packet)
    }

    // MARK: - Links

    /// Establish a link to a remote destination.
    public func createLink(to destination: RNSDestination) async throws -> RNSLink {
        let link = RNSLink(to: destination)
        let requestData = try link.createLinkRequest()
        let packet = RNSPacket.linkRequest(to: destination, data: requestData)
        _ = try await transport.sendPacket(packet)
        await transport.registerLink(link)
        return link
    }

    // MARK: - Interfaces

    /// Add a network interface at runtime.
    public func addInterface(_ interface: any RNSInterface) async {
        interface.delegate = interfaceBridge
        await transport.addInterface(interface)
    }

    /// Connect a new TCP client interface.
    public func connectTCP(name: String, host: String, port: UInt16 = RNS.defaultTCPPort) async throws {
        let interface = TCPClientInterface(name: name, host: host, port: port)
        interface.delegate = interfaceBridge
        await transport.addInterface(interface)
        try await interface.connect()
    }

    // MARK: - Announce Handlers

    /// Register a handler for incoming announces.
    public func onAnnounce(
        appName: String,
        handler: @escaping @Sendable (Data, RNSIdentity, Data?) -> Void
    ) async {
        await transport.registerAnnounceHandler(appName: appName, callback: handler)
    }

    // MARK: - Statistics

    /// Get current network statistics.
    public func statistics() async -> TransportStatistics {
        await transport.statistics()
    }

    // MARK: - Private

    private func createInterface(from config: RNSInterfaceConfig) -> (any RNSInterface)? {
        switch config.type {
        case .tcpClient:
            guard let host = config.host else { return nil }
            return TCPClientInterface(
                name: config.name,
                host: host,
                port: config.port ?? RNS.defaultTCPPort
            )
        case .tcpServer, .udp:
            // Not yet implemented
            return nil
        case .autoInterface:
            return AutoInterface(name: config.name)
        }
    }

    private func performMaintenance() async {
        await transport.cleanExpiredPaths()
    }
}

// MARK: - Interface Bridge

/// Bridges interface delegate callbacks to the transport actor.
private final class InterfaceBridge: RNSInterfaceDelegate, @unchecked Sendable {
    let transport: RNSTransport

    init(transport: RNSTransport) {
        self.transport = transport
    }

    func interface(_ interface: any RNSInterface, didReceivePacket data: Data) {
        Task {
            await transport.processIncoming(data: data, from: interface.name)
        }
    }

    func interfaceDidConnect(_ interface: any RNSInterface) {
        // Could log or notify
    }

    func interfaceDidDisconnect(_ interface: any RNSInterface, error: Error?) {
        // Could log or notify
    }
}

// MARK: - Configuration

/// Configuration for a Reticulum instance.
public struct ReticulumConfig: Sendable {
    /// Network interfaces to connect.
    public var interfaces: [RNSInterfaceConfig]

    /// Whether to enable transport mode (relay packets for others).
    public var transportEnabled: Bool

    /// Storage directory for identity and path data.
    public var storageDirectory: URL?

    public init(
        interfaces: [RNSInterfaceConfig] = [],
        transportEnabled: Bool = false,
        storageDirectory: URL? = nil
    ) {
        self.interfaces = interfaces
        self.transportEnabled = transportEnabled
        self.storageDirectory = storageDirectory
    }
}
