// SPDX-License-Identifier: MIT
// ReticulumKit — Identity.swift
// Reticulum cryptographic identity: an Ed25519 signing key + X25519 agreement key.

import Foundation
import CryptoKit

/// A Reticulum identity represents a unique cryptographic entity on the network.
/// Each identity has an Ed25519 signing keypair and an X25519 key agreement keypair.
/// The identity hash (address) is the truncated SHA-256 of the combined public keys.
public final class RNSIdentity: Identifiable, Sendable {

    // MARK: - Properties

    /// Ed25519 signing private key (nil for receive-only / remote identities).
    private let signingPrivateKey: Curve25519.Signing.PrivateKey?
    /// X25519 key agreement private key (nil for receive-only / remote identities).
    private let encryptionPrivateKey: Curve25519.KeyAgreement.PrivateKey?

    /// Ed25519 signing public key.
    public let signingPublicKey: Curve25519.Signing.PublicKey
    /// X25519 key agreement public key.
    public let encryptionPublicKey: Curve25519.KeyAgreement.PublicKey

    /// Combined public key bytes: Ed25519 pub (32 bytes) + X25519 pub (32 bytes).
    public var publicKeyBytes: Data {
        var data = Data()
        data.append(contentsOf: signingPublicKey.rawRepresentation)
        data.append(contentsOf: encryptionPublicKey.rawRepresentation)
        return data
    }

    /// Full SHA-256 hash of the combined public keys.
    public var fullHash: Data {
        RNSCrypto.sha256(publicKeyBytes)
    }

    /// Truncated identity hash (16 bytes) — the Reticulum address.
    public var hash: Data {
        RNSCrypto.truncatedHash(publicKeyBytes)
    }

    /// Hex string representation of the identity hash.
    public var hexHash: String {
        hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether this identity has private keys (can sign and decrypt).
    public var hasPrivateKeys: Bool {
        signingPrivateKey != nil && encryptionPrivateKey != nil
    }

    /// Conformance to Identifiable.
    public var id: Data { hash }

    // MARK: - Initialization

    /// Generate a new random identity with full keypairs.
    public init() {
        let sigKey = Curve25519.Signing.PrivateKey()
        let encKey = Curve25519.KeyAgreement.PrivateKey()
        self.signingPrivateKey = sigKey
        self.encryptionPrivateKey = encKey
        self.signingPublicKey = sigKey.publicKey
        self.encryptionPublicKey = encKey.publicKey
    }

    /// Create a receive-only identity from public key bytes.
    /// - Parameter publicKeyBytes: 64-byte combined public key (Ed25519 + X25519).
    public init(publicKeyBytes: Data) throws {
        guard publicKeyBytes.count == RNS.identityKeySize else {
            throw RNSIdentityError.invalidPublicKeySize
        }
        let sigPubBytes = publicKeyBytes.prefix(RNS.keySize)
        let encPubBytes = publicKeyBytes.suffix(RNS.keySize)

        self.signingPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: sigPubBytes)
        self.encryptionPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: encPubBytes)
        self.signingPrivateKey = nil
        self.encryptionPrivateKey = nil
    }

    /// Restore an identity from stored private keys.
    /// - Parameter privateKeyBytes: 64-byte combined private keys (Ed25519 + X25519).
    public init(privateKeyBytes: Data) throws {
        guard privateKeyBytes.count == RNS.identityKeySize else {
            throw RNSIdentityError.invalidPrivateKeySize
        }
        let sigPrivBytes = privateKeyBytes.prefix(RNS.keySize)
        let encPrivBytes = privateKeyBytes.suffix(RNS.keySize)

        let sigKey = try Curve25519.Signing.PrivateKey(rawRepresentation: sigPrivBytes)
        let encKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: encPrivBytes)

        self.signingPrivateKey = sigKey
        self.encryptionPrivateKey = encKey
        self.signingPublicKey = sigKey.publicKey
        self.encryptionPublicKey = encKey.publicKey
    }

    // MARK: - Signing

    /// Sign data with this identity's Ed25519 private key.
    public func sign(_ data: Data) throws -> Data {
        guard let privateKey = signingPrivateKey else {
            throw RNSIdentityError.noPrivateKey
        }
        return try RNSCrypto.sign(data: data, privateKey: privateKey)
    }

    /// Verify a signature against this identity's public key.
    public func verify(signature: Data, for data: Data) -> Bool {
        RNSCrypto.verify(signature: signature, data: data, publicKey: signingPublicKey)
    }

    // MARK: - Encryption

    /// Encrypt data so only this identity can decrypt it.
    /// Uses ephemeral X25519 key exchange + Fernet encryption.
    /// - Returns: Encrypted token prefixed with the ephemeral public key (32 bytes).
    public func encrypt(_ plaintext: Data) throws -> Data {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try RNSCrypto.x25519(
            privateKey: ephemeral,
            publicKey: encryptionPublicKey
        )
        let derivedKey = RNSCrypto.hkdf(
            inputKeyMaterial: shared,
            info: Data(),
            outputByteCount: 32
        )
        let token = try RNSFernet.encrypt(plaintext: plaintext, key: derivedKey)

        var result = Data()
        result.append(contentsOf: ephemeral.publicKey.rawRepresentation)
        result.append(token)
        return result
    }

    /// Decrypt data that was encrypted to this identity.
    /// - Parameter ciphertext: Ephemeral public key (32 bytes) + Fernet token.
    public func decrypt(_ ciphertext: Data) throws -> Data {
        guard let privateKey = encryptionPrivateKey else {
            throw RNSIdentityError.noPrivateKey
        }
        guard ciphertext.count > RNS.keySize else {
            throw RNSIdentityError.invalidCiphertext
        }

        let ephemeralPubBytes = ciphertext.prefix(RNS.keySize)
        let token = ciphertext.suffix(from: RNS.keySize)

        let ephemeralPub = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: ephemeralPubBytes
        )
        let shared = try RNSCrypto.x25519(privateKey: privateKey, publicKey: ephemeralPub)
        let derivedKey = RNSCrypto.hkdf(
            inputKeyMaterial: shared,
            info: Data(),
            outputByteCount: 32
        )

        return try RNSFernet.decrypt(token: Data(token), key: derivedKey)
    }

    // MARK: - Serialization

    /// Export private key bytes for storage (64 bytes).
    public func exportPrivateKeys() throws -> Data {
        guard let sigKey = signingPrivateKey, let encKey = encryptionPrivateKey else {
            throw RNSIdentityError.noPrivateKey
        }
        var data = Data()
        data.append(sigKey.rawRepresentation)
        data.append(encKey.rawRepresentation)
        return data
    }

    // MARK: - Announce

    /// Create an announce payload for this identity.
    /// Format: public_keys (64) + name_hash (32) + random_hash (10) + signature
    public func createAnnounce(appName: String, appData: Data? = nil) throws -> Data {
        let nameHash = RNSCrypto.nameHash(appName)
        let randomHash = RNSCrypto.randomBytes(count: 10)

        var signedPart = Data()
        signedPart.append(publicKeyBytes)
        signedPart.append(nameHash)
        signedPart.append(randomHash)
        if let appData = appData {
            signedPart.append(appData)
        }

        let signature = try sign(signedPart)

        var announce = Data()
        announce.append(signedPart)
        announce.append(signature)
        return announce
    }
}

// MARK: - Equatable / Hashable

extension RNSIdentity: Equatable {
    public static func == (lhs: RNSIdentity, rhs: RNSIdentity) -> Bool {
        lhs.hash == rhs.hash
    }
}

extension RNSIdentity: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(hash)
    }
}

// MARK: - Errors

public enum RNSIdentityError: Error, LocalizedError {
    case invalidPublicKeySize
    case invalidPrivateKeySize
    case noPrivateKey
    case invalidCiphertext
    case invalidAnnounce
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPublicKeySize: return "Public key must be \(RNS.identityKeySize) bytes"
        case .invalidPrivateKeySize: return "Private key must be \(RNS.identityKeySize) bytes"
        case .noPrivateKey: return "This identity has no private keys"
        case .invalidCiphertext: return "Invalid ciphertext format"
        case .invalidAnnounce: return "Invalid announce data"
        case .verificationFailed: return "Signature verification failed"
        }
    }
}
