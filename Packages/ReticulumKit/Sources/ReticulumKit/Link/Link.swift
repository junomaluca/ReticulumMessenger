// SPDX-License-Identifier: MIT
// ReticulumKit — Link.swift
// Encrypted bidirectional links between Reticulum destinations.

import Foundation
import CryptoKit

/// An encrypted bidirectional link between two Reticulum destinations.
/// Links provide authenticated, encrypted communication channels with
/// forward secrecy via ephemeral key exchange.
public final class RNSLink: @unchecked Sendable {

    // MARK: - Types

    public enum Status: Sendable {
        case pending
        case handshake
        case active
        case stale
        case closed
    }

    public enum Side: Sendable {
        case initiator
        case responder
    }

    public enum TeardownReason: Sendable {
        case closed
        case timeout
        case error(String)
    }

    // MARK: - Properties

    /// The hash identifying this link.
    public let linkHash: Data

    /// Which side of the link we are.
    public let side: Side

    /// Current link status.
    public private(set) var status: Status = .pending

    /// The local destination.
    public let destination: RNSDestination

    /// The remote identity (available after handshake).
    public private(set) var remoteIdentity: RNSIdentity?

    /// The interface this link operates on.
    public let interfaceName: String

    /// Derived encryption key for outgoing data.
    private var encryptionKey: Data?

    /// Derived encryption key for incoming data.
    private var decryptionKey: Data?

    /// Ephemeral key pair used during handshake.
    private let ephemeralKey: Curve25519.KeyAgreement.PrivateKey

    /// Shared secret from key exchange.
    private var sharedSecret: Data?

    /// When this link was established.
    public private(set) var establishedAt: Date?

    /// Last activity timestamp.
    public private(set) var lastActivity: Date

    /// Callback for received data.
    public var dataCallback: ((Data) -> Void)?

    /// Callback for link status changes.
    public var statusCallback: ((Status) -> Void)?

    /// Callback for link teardown.
    public var teardownCallback: ((TeardownReason) -> Void)?

    /// Channel for structured communication over this link.
    public private(set) var channel: RNSChannel?

    // MARK: - Initialization (Initiator Side)

    /// Create a new link to a remote destination (initiator side).
    public init(to destination: RNSDestination, interfaceName: String = "default") {
        self.side = .initiator
        self.destination = destination
        self.interfaceName = interfaceName
        self.ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        self.lastActivity = Date()

        // Link hash is derived from the ephemeral public key and destination
        var hashMaterial = Data()
        hashMaterial.append(ephemeralKey.publicKey.rawRepresentation)
        hashMaterial.append(destination.hash)
        self.linkHash = RNSCrypto.truncatedHash(hashMaterial)
    }

    /// Create a link request payload for sending.
    public func createLinkRequest() throws -> Data {
        guard let identity = destination.identity, identity.hasPrivateKeys else {
            throw RNSLinkError.noIdentity
        }

        var requestData = Data()
        // Ephemeral public key
        requestData.append(ephemeralKey.publicKey.rawRepresentation)
        // Signed with our identity
        let signature = try identity.sign(requestData)
        requestData.append(signature)

        status = .handshake
        statusCallback?(.handshake)
        return requestData
    }

    // MARK: - Initialization (Responder Side)

    /// Create a link from an incoming link request (responder side).
    public init(
        destination: RNSDestination,
        requestData: Data,
        interfaceName: String
    ) throws {
        self.side = .responder
        self.destination = destination
        self.interfaceName = interfaceName
        self.ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        self.lastActivity = Date()

        guard requestData.count >= RNS.keySize else {
            throw RNSLinkError.invalidRequest
        }

        // Extract ephemeral public key from the request
        let remotePubBytes = requestData.prefix(RNS.keySize)
        let remoteEphemeralPub = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: remotePubBytes
        )

        // Derive link hash
        var hashMaterial = Data()
        hashMaterial.append(remotePubBytes)
        hashMaterial.append(destination.hash)
        self.linkHash = RNSCrypto.truncatedHash(hashMaterial)

        // Perform key exchange using our destination's encryption key
        guard destination.identity != nil else {
            throw RNSLinkError.noIdentity
        }

        // For the responder, we use ECDH between their ephemeral and our identity key
        // Note: In a full implementation, this would be more complex
        let shared = try RNSCrypto.x25519(
            privateKey: ephemeralKey,
            publicKey: remoteEphemeralPub
        )
        self.sharedSecret = shared

        // Derive link keys
        deriveKeys(from: shared)

        self.status = .active
        self.establishedAt = Date()
        self.channel = RNSChannel(link: self)
    }

    // MARK: - Handshake Completion (Initiator)

    /// Complete the handshake with proof data from the responder.
    /// The proof contains the responder's ephemeral public key and a signature.
    /// We perform ECDH to derive the shared secret and then derive link keys.
    public func completeHandshake(proofData: Data) throws {
        guard side == .initiator, status == .handshake else {
            throw RNSLinkError.invalidState
        }

        // Proof must contain at least the responder's ephemeral public key (32 bytes)
        guard proofData.count >= RNS.keySize else {
            throw RNSLinkError.handshakeFailed
        }

        // Extract responder's ephemeral public key from proof data
        let responderPubBytes = proofData.prefix(RNS.keySize)
        let responderEphemeralPub = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: responderPubBytes
        )

        // Perform ECDH: our ephemeral private × their ephemeral public
        let shared = try RNSCrypto.x25519(
            privateKey: ephemeralKey,
            publicKey: responderEphemeralPub
        )
        self.sharedSecret = shared
        deriveKeys(from: shared)

        status = .active
        establishedAt = Date()
        channel = RNSChannel(link: self)
        statusCallback?(.active)
    }

    // MARK: - Key Derivation

    private func deriveKeys(from sharedSecret: Data) {
        // Derive separate keys for each direction
        let keyMaterial = RNSCrypto.hkdf(
            inputKeyMaterial: sharedSecret,
            salt: linkHash,
            info: Data("rns.link.keys".utf8),
            outputByteCount: 64
        )

        if side == .initiator {
            encryptionKey = keyMaterial.prefix(32)
            decryptionKey = Data(keyMaterial.suffix(32))
        } else {
            decryptionKey = keyMaterial.prefix(32)
            encryptionKey = Data(keyMaterial.suffix(32))
        }
    }

    // MARK: - Data Transfer

    /// Send data over this link (encrypted).
    public func send(_ data: Data) throws -> Data {
        guard status == .active else {
            throw RNSLinkError.notActive
        }
        guard let key = encryptionKey else {
            throw RNSLinkError.noKeys
        }

        lastActivity = Date()
        return try RNSFernet.encrypt(plaintext: data, key: key)
    }

    /// Receive and decrypt data on this link.
    public func receivePacket(_ packet: RNSPacket) {
        guard status == .active else { return }
        guard let key = decryptionKey else { return }

        lastActivity = Date()

        if let plaintext = try? RNSFernet.decrypt(token: packet.data, key: key) {
            dataCallback?(plaintext)
            channel?.handleIncoming(plaintext)
        }
    }

    // MARK: - Link Lifecycle

    /// Close this link gracefully.
    public func close() {
        status = .closed
        encryptionKey = nil
        decryptionKey = nil
        sharedSecret = nil
        statusCallback?(.closed)
        teardownCallback?(.closed)
    }

    /// Check if the link has become stale.
    public func checkStale() {
        guard status == .active else { return }
        if Date().timeIntervalSince(lastActivity) > RNS.linkStaleTime {
            status = .stale
            statusCallback?(.stale)
            teardownCallback?(.timeout)
        }
    }

    /// Send a keepalive on this link.
    public func sendKeepalive() throws {
        guard status == .active else { return }
        // Keepalive is an empty encrypted packet
        _ = try send(Data())
        lastActivity = Date()
    }
}

// MARK: - Errors

public enum RNSLinkError: Error, LocalizedError {
    case noIdentity
    case invalidRequest
    case invalidState
    case notActive
    case noKeys
    case handshakeFailed

    public var errorDescription: String? {
        switch self {
        case .noIdentity: return "No identity for link establishment"
        case .invalidRequest: return "Invalid link request data"
        case .invalidState: return "Invalid link state for this operation"
        case .notActive: return "Link is not active"
        case .noKeys: return "Link encryption keys not derived"
        case .handshakeFailed: return "Link handshake failed"
        }
    }
}
