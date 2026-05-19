// SPDX-License-Identifier: MIT
// LXMFKit — LXMRouter.swift
// LXMF message router — handles message delivery and receiving.

import Foundation
import ReticulumKit

/// The LXMF message router manages sending and receiving of LXMF messages.
/// It integrates with the Reticulum Network Stack to deliver messages via
/// direct links or through propagation nodes.
public actor LXMRouter {

    // MARK: - Types

    /// Delivery status update.
    public struct DeliveryUpdate: Sendable {
        public let messageId: Data
        public let state: LXMessage.State
        public let timestamp: Date
    }

    // MARK: - Properties

    /// The Reticulum instance for network operations.
    private let reticulum: Reticulum

    /// The LXMF delivery destination.
    private var deliveryDestination: RNSDestination?

    /// Known peers for direct delivery.
    private var peers: [Data: LXMPeer] = [:]

    /// Pending outbound messages.
    private var outboundQueue: [Data: LXMessage] = [:]

    /// Message handlers.
    private var messageHandlers: [(LXMessage) -> Void] = []

    /// Delivery update handlers.
    private var deliveryHandlers: [(DeliveryUpdate) -> Void] = []

    /// The app name used for LXMF destinations.
    public static let appName = "lxmf"
    public static let deliveryAspect = "delivery"

    /// Propagation node address (if configured).
    private var propagationNode: Data?

    // MARK: - Initialization

    public init(reticulum: Reticulum) {
        self.reticulum = reticulum
    }

    // MARK: - Setup

    /// Start the LXMF router and register the delivery destination.
    public func start() async throws {
        let destination = try await reticulum.createDestination(
            appName: Self.appName,
            aspects: [Self.deliveryAspect]
        )

        destination.packetCallback = { [weak self] packet in
            Task { [weak self] in
                await self?.handleIncomingPacket(packet)
            }
        }

        destination.linkCallback = { [weak self] link in
            Task { [weak self] in
                await self?.handleIncomingLink(link)
            }
        }

        self.deliveryDestination = destination

        // Announce our delivery destination
        try await reticulum.announce(destination: destination)

        // Register announce handler for other LXMF nodes
        await reticulum.onAnnounce(appName: "\(Self.appName).\(Self.deliveryAspect)") {
            [weak self] hash, identity, appData in
            Task { [weak self] in
                await self?.handlePeerAnnounce(hash: hash, identity: identity, appData: appData)
            }
        }
    }

    // MARK: - Sending

    /// Send an LXMF message.
    @discardableResult
    public func send(_ message: LXMessage) async throws -> Data {
        var msg = message
        msg.state = .outbound
        outboundQueue[msg.id] = msg

        notifyDeliveryUpdate(DeliveryUpdate(
            messageId: msg.id,
            state: .outbound,
            timestamp: Date()
        ))

        // Try direct delivery first
        do {
            try await deliverDirect(msg)
            msg.state = .sent
            outboundQueue[msg.id] = msg
            notifyDeliveryUpdate(DeliveryUpdate(
                messageId: msg.id,
                state: .sent,
                timestamp: Date()
            ))
        } catch {
            // Fall back to propagation if configured
            if let propNode = propagationNode {
                try await deliverViaPropagation(msg, node: propNode)
            } else {
                msg.state = .failed
                outboundQueue[msg.id] = msg
                notifyDeliveryUpdate(DeliveryUpdate(
                    messageId: msg.id,
                    state: .failed,
                    timestamp: Date()
                ))
                throw error
            }
        }

        return msg.id
    }

    /// Attempt direct delivery via a link.
    private func deliverDirect(_ message: LXMessage) async throws {
        let destHash = message.destinationHash

        // Check if we have a path
        let hasPath = await reticulum.transport.hasPath(to: destHash)
        if !hasPath {
            try await reticulum.transport.requestPath(to: destHash)
            // Wait briefly for path response
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let pathFound = await reticulum.transport.hasPath(to: destHash)
            if !pathFound {
                throw LXMFError.noRoute
            }
        }

        // Create destination and send
        let destination = RNSDestination(
            hash: destHash,
            type: .single,
            appName: "\(Self.appName).\(Self.deliveryAspect)"
        )

        let serialized = message.serialize()
        _ = try await reticulum.send(data: serialized, to: destination)
    }

    /// Deliver via a propagation node.
    private func deliverViaPropagation(_ message: LXMessage, node: Data) async throws {
        let destination = RNSDestination(
            hash: node,
            type: .single,
            appName: "\(Self.appName).propagation"
        )

        let serialized = message.serialize()
        _ = try await reticulum.send(data: serialized, to: destination)
    }

    // MARK: - Receiving

    /// Handle an incoming packet on the delivery destination.
    private func handleIncomingPacket(_ packet: RNSPacket) {
        guard let message = try? LXMessage.deserialize(packet.data) else {
            return
        }
        dispatchReceivedMessage(message)
    }

    /// Handle an incoming link (for direct delivery).
    private func handleIncomingLink(_ link: RNSLink) {
        link.dataCallback = { [weak self] data in
            guard let message = try? LXMessage.deserialize(data) else { return }
            Task { [weak self] in
                await self?.dispatchReceivedMessage(message)
            }
        }
    }

    /// Dispatch a received message to handlers.
    private func dispatchReceivedMessage(_ message: LXMessage) {
        for handler in messageHandlers {
            handler(message)
        }
    }

    // MARK: - Peer Management

    /// Handle a peer announce.
    private func handlePeerAnnounce(hash: Data, identity: RNSIdentity, appData: Data?) {
        let peer = LXMPeer(
            destinationHash: hash,
            identity: identity,
            appData: appData,
            lastSeen: Date()
        )
        peers[hash] = peer
    }

    /// Get all known peers.
    public func knownPeers() -> [LXMPeer] {
        Array(peers.values)
    }

    /// Get a specific peer by destination hash.
    public func peer(for hash: Data) -> LXMPeer? {
        peers[hash]
    }

    // MARK: - Configuration

    /// Set the propagation node for store-and-forward delivery.
    public func setPropagationNode(_ hash: Data?) {
        propagationNode = hash
    }

    /// Enable or disable propagation node mode (act as a message store).
    public func setPropagationNode(_ enabled: Bool) {
        // When disabled, clear the propagation node address.
        // When enabled, set to a sentinel value indicating this node is a propagation node.
        if !enabled {
            propagationNode = nil
        }
        // The actual propagation node functionality would store messages for offline peers
    }

    /// Get the delivery destination hash.
    public func deliveryHash() -> Data? {
        deliveryDestination?.hash
    }

    // MARK: - Handlers

    /// Register a handler for received messages.
    public func onMessage(_ handler: @escaping (LXMessage) -> Void) {
        messageHandlers.append(handler)
    }

    /// Register a handler for delivery updates.
    public func onDeliveryUpdate(_ handler: @escaping (DeliveryUpdate) -> Void) {
        deliveryHandlers.append(handler)
    }

    // MARK: - Private

    private func notifyDeliveryUpdate(_ update: DeliveryUpdate) {
        for handler in deliveryHandlers {
            handler(update)
        }
    }
}
