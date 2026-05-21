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

    /// Failed messages queued for retry.
    private var retryQueue: [LXMessage] = []

    /// Maximum number of delivery retries per message.
    private let maxRetries = 3

    /// Retry interval in seconds.
    private let retryInterval: TimeInterval = 30.0

    /// Retry processing task.
    private var retryTask: Task<Void, Never>?

    /// Message handlers.
    private var messageHandlers: [(LXMessage) -> Void] = []

    /// Delivery update handlers.
    private var deliveryHandlers: [(DeliveryUpdate) -> Void] = []

    /// Diagnostic counters for message reception pipeline.
    public private(set) var packetsReceived: UInt64 = 0
    public private(set) var deserializeFailures: UInt64 = 0
    public private(set) var messagesDelivered: UInt64 = 0
    public private(set) var lastDeserializeError: String?

    /// Diagnostic counters for sending pipeline.
    public private(set) var sendAttempts: UInt64 = 0
    public private(set) var sendSuccesses: UInt64 = 0
    public private(set) var sendFailures: UInt64 = 0
    public private(set) var lastSendError: String?

    /// A single entry in the per-message diagnostic log.
    public struct LogEntry: Sendable {
        public enum Direction: String, Sendable { case send, recv }
        public enum Outcome: String, Sendable { case ok, failed }
        public let timestamp: Date
        public let direction: Direction
        public let outcome: Outcome
        public let peerHex: String
        public let bytes: Int
        public let title: String?
        public let attachmentCount: Int
        public let note: String?
    }

    /// Ring buffer of recent message events (sends + receives), newest last.
    /// Surfaced in DiagnosticsService so per-message failures are visible.
    public private(set) var messageLog: [LogEntry] = []
    private let messageLogMax = 30

    private func appendLog(_ entry: LogEntry) {
        messageLog.append(entry)
        if messageLog.count > messageLogMax {
            messageLog.removeFirst(messageLog.count - messageLogMax)
        }
    }

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

    // MARK: - Retry Queue

    /// Queue a failed message for retry delivery.
    private func queueForRetry(_ message: LXMessage) {
        var msg = message
        msg.retryCount = (msg.retryCount ?? 0) + 1

        if (msg.retryCount ?? 0) <= maxRetries {
            retryQueue.append(msg)
            startRetryProcessor()
        } else {
            msg.state = .failed
            outboundQueue[msg.id] = msg
            notifyDeliveryUpdate(DeliveryUpdate(
                messageId: msg.id,
                state: .failed,
                timestamp: Date()
            ))
        }
    }

    /// Start the background retry processor if not already running.
    private func startRetryProcessor() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.retryInterval ?? 30.0) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.processRetryQueue()
            }
        }
    }

    /// Process pending retry messages.
    private func processRetryQueue() async {
        guard !retryQueue.isEmpty else {
            retryTask?.cancel()
            retryTask = nil
            return
        }

        let batch = retryQueue
        retryQueue.removeAll()

        for message in batch {
            do {
                try await deliverDirect(message)
                var msg = message
                msg.state = .sent
                outboundQueue[msg.id] = msg
                notifyDeliveryUpdate(DeliveryUpdate(
                    messageId: msg.id,
                    state: .sent,
                    timestamp: Date()
                ))
            } catch {
                // Re-queue if still under retry limit
                queueForRetry(message)
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
        sendAttempts += 1
        let serializedSize = msg.serialize().count
        do {
            try await deliverDirect(msg)
            msg.state = .sent
            sendSuccesses += 1
            outboundQueue[msg.id] = msg
            appendLog(LogEntry(
                timestamp: Date(),
                direction: .send,
                outcome: .ok,
                peerHex: msg.destinationHash.map { String(format: "%02x", $0) }.joined(),
                bytes: serializedSize,
                title: msg.title,
                attachmentCount: msg.attachments.count,
                note: nil
            ))
            notifyDeliveryUpdate(DeliveryUpdate(
                messageId: msg.id,
                state: .sent,
                timestamp: Date()
            ))
        } catch {
            sendFailures += 1
            lastSendError = error.localizedDescription
            appendLog(LogEntry(
                timestamp: Date(),
                direction: .send,
                outcome: .failed,
                peerHex: msg.destinationHash.map { String(format: "%02x", $0) }.joined(),
                bytes: serializedSize,
                title: msg.title,
                attachmentCount: msg.attachments.count,
                note: error.localizedDescription
            ))
            // Fall back to propagation if configured
            if let propNode = propagationNode {
                do {
                    try await deliverViaPropagation(msg, node: propNode)
                } catch {
                    queueForRetry(msg)
                    throw error
                }
            } else {
                queueForRetry(msg)
                throw error
            }
        }

        return msg.id
    }

    /// Attempt direct delivery via a single encrypted packet.
    /// Uses transport's waitForPath() with proper timeout instead of a fixed sleep.
    /// When the recipient's identity is known (from a prior announce), we build
    /// an identity-bearing destination so `RNSPacket.data()` encrypts to it,
    /// matching Python reference clients. Without an identity we still send raw
    /// bytes (legacy iOS-to-iOS path).
    private func deliverDirect(_ message: LXMessage) async throws {
        let destHash = message.destinationHash

        // Check if we have a path, request one if not
        let hasPath = await reticulum.transport.hasPath(to: destHash)
        if !hasPath {
            try await reticulum.transport.requestPath(to: destHash)
            let pathFound = await reticulum.transport.waitForPath(to: destHash, timeout: 10.0)
            if !pathFound {
                throw LXMFError.noRoute
            }
        }

        let destination: RNSDestination
        if let peer = peers[destHash] {
            destination = RNSDestination(
                identity: peer.identity,
                type: .single,
                appName: Self.appName,
                aspects: [Self.deliveryAspect]
            )
        } else {
            destination = RNSDestination(
                hash: destHash,
                type: .single,
                appName: "\(Self.appName).\(Self.deliveryAspect)"
            )
        }

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
    /// Tries to decrypt the payload with our identity (Python-RNS compatible
    /// senders encrypt to us). Falls back to the raw bytes for legacy
    /// iOS-to-iOS senders that never encrypted.
    private func handleIncomingPacket(_ packet: RNSPacket) {
        packetsReceived += 1

        let plaintext: Data
        if let decrypted = try? deliveryDestination?.decrypt(packet.data) {
            plaintext = decrypted
        } else {
            plaintext = packet.data
        }

        do {
            let message = try LXMessage.deserialize(plaintext)
            messagesDelivered += 1
            appendLog(LogEntry(
                timestamp: Date(),
                direction: .recv,
                outcome: .ok,
                peerHex: message.sourceHash.map { String(format: "%02x", $0) }.joined(),
                bytes: plaintext.count,
                title: message.title,
                attachmentCount: message.attachments.count,
                note: nil
            ))
            dispatchReceivedMessage(message)
        } catch {
            deserializeFailures += 1
            let firstBytes = plaintext.prefix(4).map { String(format: "%02x", $0) }.joined()
            lastDeserializeError = "\(error.localizedDescription) (pkt \(packet.data.count)B, plain \(plaintext.count)B, first: \(firstBytes))"
            appendLog(LogEntry(
                timestamp: Date(),
                direction: .recv,
                outcome: .failed,
                peerHex: "(unknown)",
                bytes: plaintext.count,
                title: nil,
                attachmentCount: 0,
                note: "deserialize failed; first=\(firstBytes); \(error.localizedDescription)"
            ))
        }
    }

    /// Handle an incoming link (for direct delivery via Resource).
    private func handleIncomingLink(_ link: RNSLink) {
        link.dataCallback = { [weak self] data in
            guard let self = self else { return }
            Task { [weak self] in
                guard let self = self else { return }
                let plaintext: Data
                if let decrypted = try? await self.tryDecrypt(data) {
                    plaintext = decrypted
                } else {
                    plaintext = data
                }
                if let message = try? LXMessage.deserialize(plaintext) {
                    await self.dispatchReceivedMessage(message)
                }
            }
        }
    }

    private func tryDecrypt(_ data: Data) async throws -> Data {
        guard let dest = deliveryDestination else { throw LXMFError.encryptionFailed }
        return try dest.decrypt(data)
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

    /// Get the delivery destination (for announces without overwriting callbacks).
    public func getDeliveryDestination() -> RNSDestination? {
        deliveryDestination
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
