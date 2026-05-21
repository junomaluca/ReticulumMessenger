// SPDX-License-Identifier: MIT
// ReticulumKit — Destination.swift
// Addressable endpoints on the Reticulum network.

import Foundation

/// A Reticulum destination represents an addressable endpoint on the network.
/// Destinations are identified by a hash derived from the owning identity
/// and a hierarchical application name (e.g., "myapp.messaging").
public final class RNSDestination: @unchecked Sendable {

    // MARK: - Properties

    /// The type of this destination.
    public let type: RNS.DestinationType

    /// The identity that owns this destination (nil for group/plain types).
    public let identity: RNSIdentity?

    /// Hierarchical application name (e.g., "lxmf.delivery").
    public let appName: String

    /// Optional aspects appended to the app name.
    public let aspects: [String]

    /// The full app name including aspects.
    public var fullAppName: String {
        if aspects.isEmpty {
            return appName
        }
        return appName + "." + aspects.joined(separator: ".")
    }

    /// The destination hash (16 bytes).
    public let hash: Data

    /// Hex string of the destination hash.
    public var hexHash: String {
        hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Optional name for display purposes.
    public var displayName: String?

    /// Callback for incoming packets.
    public var packetCallback: ((RNSPacket) -> Void)?

    /// Callback for incoming link requests.
    public var linkCallback: ((RNSLink) -> Void)?

    /// Proof strategy: whether to automatically prove incoming packets.
    public var proofStrategy: ProofStrategy = .none

    // MARK: - Initialization

    /// Create a destination for a specific identity and application.
    /// - Parameters:
    ///   - identity: The owning identity.
    ///   - type: Destination type (default: .single).
    ///   - appName: The application name.
    ///   - aspects: Additional name aspects.
    public init(
        identity: RNSIdentity,
        type: RNS.DestinationType = .single,
        appName: String,
        aspects: [String] = []
    ) {
        self.identity = identity
        self.type = type
        self.appName = appName
        self.aspects = aspects

        // Compute destination hash
        let fullName = aspects.isEmpty ? appName : appName + "." + aspects.joined(separator: ".")
        let nameHash = RNSCrypto.nameHash(fullName)
        var addrMaterial = Data()
        addrMaterial.append(nameHash)
        addrMaterial.append(identity.hash)
        self.hash = RNSCrypto.truncatedHash(addrMaterial)
    }

    /// Create a destination from a known hash (for addressing remote destinations).
    /// - Parameters:
    ///   - hash: The 16-byte destination hash.
    ///   - type: Destination type.
    ///   - appName: The application name.
    public init(hash: Data, type: RNS.DestinationType = .single, appName: String) {
        self.hash = hash
        self.type = type
        self.appName = appName
        self.aspects = []
        self.identity = nil
    }

    // MARK: - Encryption

    /// Encrypt data for this destination.
    /// Only works for single-type destinations with an associated identity.
    public func encrypt(_ plaintext: Data) throws -> Data {
        guard let identity = identity else {
            throw RNSDestinationError.noIdentity
        }
        return try identity.encrypt(plaintext)
    }

    /// Decrypt data received at this destination.
    public func decrypt(_ ciphertext: Data) throws -> Data {
        guard let identity = identity else {
            throw RNSDestinationError.noIdentity
        }
        return try identity.decrypt(ciphertext)
    }

    /// Sign data from this destination.
    public func sign(_ data: Data) throws -> Data {
        guard let identity = identity else {
            throw RNSDestinationError.noIdentity
        }
        return try identity.sign(data)
    }

    // MARK: - Announce

    /// Create an announce packet for this destination.
    public func announce(appData: Data? = nil) throws -> Data {
        guard let identity = identity, identity.hasPrivateKeys else {
            throw RNSDestinationError.cannotAnnounce
        }
        return try identity.createAnnounce(appName: fullAppName, destinationHash: hash, appData: appData)
    }

    // MARK: - Types

    public enum ProofStrategy {
        case none
        case proveAll
        case proveApp
    }
}

// MARK: - Equatable / Hashable

extension RNSDestination: Equatable {
    public static func == (lhs: RNSDestination, rhs: RNSDestination) -> Bool {
        lhs.hash == rhs.hash
    }
}

extension RNSDestination: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(hash)
    }
}

// MARK: - Errors

public enum RNSDestinationError: Error, LocalizedError {
    case noIdentity
    case cannotAnnounce
    case invalidHash

    public var errorDescription: String? {
        switch self {
        case .noIdentity: return "Destination has no associated identity"
        case .cannotAnnounce: return "Cannot announce without private keys"
        case .invalidHash: return "Invalid destination hash"
        }
    }
}
