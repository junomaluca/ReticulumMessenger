// SPDX-License-Identifier: MIT
// ReticulumMessenger — MessengerService.swift
// Bridges the LXMF router with the app's conversation model.

import Foundation
import ReticulumKit
import LXMFKit

/// Service that coordinates message sending/receiving with conversation management.
actor MessengerService {

    // MARK: - Properties

    private let reticulum: Reticulum
    private let router: LXMRouter
    private let storage: StorageService

    /// Cached delivery destination to avoid re-creating and overwriting callbacks.
    private var cachedDeliveryDestination: RNSDestination?

    // MARK: - Initialization

    init(reticulum: Reticulum, router: LXMRouter, storage: StorageService) {
        self.reticulum = reticulum
        self.router = router
        self.storage = storage
    }

    // MARK: - Sending

    /// Send a text message to a destination.
    func sendMessage(content: String, to destinationHash: Data) async throws -> LXMessage {
        let identity = try await reticulum.getLocalIdentity()

        var message = LXMessage(
            sourceHash: identity.hash,
            destinationHash: destinationHash,
            content: content
        )

        // Set source name if available
        message.sourceName = storage.loadDisplayName()

        _ = try await router.send(message)
        return message
    }

    /// Get all known peers from the LXMF router.
    func getKnownPeers() async -> [LXMPeer] {
        await router.knownPeers()
    }

    /// Get the local delivery hash.
    func getDeliveryHash() async -> Data? {
        await router.deliveryHash()
    }

    /// Announce presence on the network.
    /// Reuses the existing delivery destination to avoid overwriting router callbacks.
    func announce(displayName: String?) async throws {
        let destination: RNSDestination

        if let cached = cachedDeliveryDestination {
            destination = cached
        } else {
            // Get the delivery destination from the router instead of creating a new one
            destination = try await reticulum.createDestination(
                appName: LXMRouter.appName,
                aspects: [LXMRouter.deliveryAspect]
            )
            cachedDeliveryDestination = destination
        }

        let appData = displayName.map { Data($0.utf8) }
        try await reticulum.announce(destination: destination, appData: appData)
    }
}
