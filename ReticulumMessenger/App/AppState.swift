// SPDX-License-Identifier: MIT
// ReticulumMessenger — AppState.swift
// Central app state coordinating the Reticulum stack, LXMF router, and UI.

import SwiftUI
import ReticulumKit
import LXMFKit

/// Central observable state for the application.
/// Bridges the Reticulum/LXMF protocol layer with SwiftUI views.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published State

    @Published var isInitialized = false
    @Published var networkStatus: NetworkStatus = .disconnected
    @Published var conversations: [Conversation] = []
    @Published var knownPeers: [PeerInfo] = []
    @Published var interfaces: [InterfaceInfo] = []
    @Published var localIdentityHash: String = ""
    @Published var deliveryHash: String = ""

    // MARK: - Services

    private(set) var messengerService: MessengerService?
    private(set) var storageService: StorageService?

    // MARK: - Protocol Layer

    private var reticulum: Reticulum?
    private var lxmRouter: LXMRouter?

    // MARK: - Initialization

    func initialize() async {
        guard !isInitialized else { return }

        // Initialize storage
        let storage = StorageService()
        self.storageService = storage

        // Load saved conversations and settings
        conversations = storage.loadConversations()
        let savedInterfaces = storage.loadInterfaceConfigs()

        // Initialize Reticulum stack
        let config = ReticulumConfig(
            interfaces: savedInterfaces.isEmpty ? defaultInterfaces() : savedInterfaces
        )
        let rns = Reticulum(config: config)
        self.reticulum = rns

        // Initialize LXMF router
        let router = LXMRouter(reticulum: rns)
        self.lxmRouter = router

        // Initialize messenger service
        let messenger = MessengerService(
            reticulum: rns,
            router: router,
            storage: storage
        )
        self.messengerService = messenger

        // Start the stack
        do {
            try await rns.start()
            try await router.start()

            // Set identity info
            if let identity = await rns.localIdentity {
                localIdentityHash = identity.hexHash
            }
            if let hash = await router.deliveryHash() {
                deliveryHash = hash.map { String(format: "%02x", $0) }.joined()
            }

            // Register message handler
            await router.onMessage { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.handleReceivedMessage(message)
                }
            }

            networkStatus = .connected
            isInitialized = true

            // Start periodic UI updates
            startPeriodicUpdates()

        } catch {
            networkStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Messaging

    func sendMessage(content: String, to destinationHash: Data) async throws {
        guard let router = lxmRouter, let rns = reticulum else { return }

        let identity = try await rns.getLocalIdentity()
        let message = LXMessage(
            sourceHash: identity.hash,
            destinationHash: destinationHash,
            content: content
        )

        // Add to conversation immediately (optimistic)
        addMessageToConversation(message)

        // Send via LXMF router
        _ = try await router.send(message)
    }

    func createConversation(with destinationHash: Data, name: String?) {
        guard !conversations.contains(where: { $0.peerHash == destinationHash }) else { return }

        let conversation = Conversation(
            peerHash: destinationHash,
            displayName: name,
            messages: [],
            lastActivity: Date()
        )
        conversations.insert(conversation, at: 0)
        storageService?.saveConversations(conversations)
    }

    // MARK: - Interface Management

    func addTCPInterface(name: String, host: String, port: UInt16) async throws {
        guard let rns = reticulum else { return }
        try await rns.connectTCP(name: name, host: host, port: port)
        await refreshInterfaces()
    }

    // MARK: - Private

    private func handleReceivedMessage(_ message: LXMessage) {
        addMessageToConversation(message)
    }

    private func addMessageToConversation(_ message: LXMessage) {
        let peerHash = message.isIncoming ? message.sourceHash : message.destinationHash
        let chatMessage = ChatMessage(from: message)

        if let idx = conversations.firstIndex(where: { $0.peerHash == peerHash }) {
            conversations[idx].messages.append(chatMessage)
            conversations[idx].lastActivity = Date()
            // Move to top
            let conv = conversations.remove(at: idx)
            conversations.insert(conv, at: 0)
        } else {
            // New conversation
            let conversation = Conversation(
                peerHash: peerHash,
                displayName: message.sourceName,
                messages: [chatMessage],
                lastActivity: Date()
            )
            conversations.insert(conversation, at: 0)
        }

        storageService?.saveConversations(conversations)
    }

    private func refreshInterfaces() async {
        guard let rns = reticulum else { return }
        let ifaces = await rns.transport.getInterfaces()
        interfaces = ifaces.map { InterfaceInfo(from: $0) }
    }

    private func startPeriodicUpdates() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                await refreshInterfaces()
                if let router = lxmRouter {
                    let peers = await router.knownPeers()
                    knownPeers = peers.map { PeerInfo(from: $0) }
                }
                if let rns = reticulum {
                    let stats = await rns.statistics()
                    if stats.onlineInterfaces > 0 {
                        networkStatus = .connected
                    } else {
                        networkStatus = .connecting
                    }
                }
            }
        }
    }

    private func defaultInterfaces() -> [RNSInterfaceConfig] {
        // Default: no interfaces configured, user must add one
        []
    }
}

// MARK: - Network Status

enum NetworkStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var color: Color {
        switch self {
        case .disconnected: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        case .error: return .red
        }
    }

    var systemImage: String {
        switch self {
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .connected: return "antenna.radiowaves.left.and.right"
        case .error: return "exclamationmark.triangle"
        }
    }
}
