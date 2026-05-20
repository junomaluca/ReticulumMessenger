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

    // MARK: - Initialization

    init(reticulum: Reticulum, router: LXMRouter, storage: StorageService) {
        self.reticulum = reticulum
        self.router = router
        self.storage = storage
    }

    // MARK: - Errors

    enum MessengerError: Error, LocalizedError {
        case noDeliveryDestination

        var errorDescription: String? {
            switch self {
            case .noDeliveryDestination:
                return "LXMF router has no delivery destination — call start() first"
            }
        }
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
    /// Uses the router's existing delivery destination to avoid overwriting its callbacks.
    /// When location is provided, it is encoded in appData as `name\x1Elat,lon`.
    func announce(displayName: String?, latitude: Double? = nil, longitude: Double? = nil) async throws {
        guard let destination = await router.getDeliveryDestination() else {
            throw MessengerError.noDeliveryDestination
        }
        var payload = displayName ?? ""
        if let lat = latitude, let lon = longitude {
            payload += "\u{1E}\(lat),\(lon)"
        }
        let appData = payload.isEmpty ? nil : Data(payload.utf8)
        try await reticulum.announce(destination: destination, appData: appData)
    }
}
