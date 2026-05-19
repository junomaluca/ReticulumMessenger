// SPDX-License-Identifier: MIT
// ReticulumKit — IdentityStorage.swift
// Persistent storage for identities and known peers.

import Foundation

/// Manages persistent storage of identities.
/// Stores identity private keys in the app's secure container and
/// maintains a table of known remote identities (public keys only).
public actor IdentityStorage {

    // MARK: - Properties

    private let storageDirectory: URL
    private var knownIdentities: [Data: RNSIdentity] = [:]
    private let fileManager = FileManager.default

    // MARK: - Initialization

    public init(directory: URL? = nil) {
        if let dir = directory {
            self.storageDirectory = dir
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.storageDirectory = appSupport.appendingPathComponent("ReticulumKit/identities")
        }
    }

    // MARK: - Local Identity Management

    /// Save a local identity's private keys to disk.
    public func save(identity: RNSIdentity, name: String = "primary") throws {
        try ensureDirectory()
        let keyData = try identity.exportPrivateKeys()
        let fileURL = storageDirectory.appendingPathComponent("\(name).identity")
        try keyData.write(to: fileURL, options: .completeFileProtection)
    }

    /// Load a local identity from disk.
    public func load(name: String = "primary") throws -> RNSIdentity? {
        let fileURL = storageDirectory.appendingPathComponent("\(name).identity")
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let keyData = try Data(contentsOf: fileURL)
        return try RNSIdentity(privateKeyBytes: keyData)
    }

    /// Load the primary identity, creating one if it doesn't exist.
    public func loadOrCreate(name: String = "primary") throws -> RNSIdentity {
        if let existing = try load(name: name) {
            return existing
        }
        let identity = RNSIdentity()
        try save(identity: identity, name: name)
        return identity
    }

    /// Delete a stored identity.
    public func delete(name: String = "primary") throws {
        let fileURL = storageDirectory.appendingPathComponent("\(name).identity")
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    /// List all stored identity names.
    public func listStoredIdentities() throws -> [String] {
        try ensureDirectory()
        let contents = try fileManager.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        )
        return contents
            .filter { $0.pathExtension == "identity" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    // MARK: - Known Identity Cache

    /// Register a remote identity (public key only) in the known identities cache.
    public func remember(identity: RNSIdentity) {
        knownIdentities[identity.hash] = identity
    }

    /// Look up a known identity by its hash.
    public func recall(hash: Data) -> RNSIdentity? {
        knownIdentities[hash]
    }

    /// Remove a known identity from the cache.
    public func forget(hash: Data) {
        knownIdentities.removeValue(forKey: hash)
    }

    /// Get all known identity hashes.
    public func allKnownHashes() -> [Data] {
        Array(knownIdentities.keys)
    }

    // MARK: - Persistence of Known Identities

    /// Save the known identities cache to disk.
    public func saveKnownIdentities() throws {
        try ensureDirectory()
        let fileURL = storageDirectory.appendingPathComponent("known_identities.dat")
        var data = Data()

        for (_, identity) in knownIdentities {
            let pubKey = identity.publicKeyBytes
            // Length-prefixed: 2 bytes for length + public key bytes
            var length = UInt16(pubKey.count)
            data.append(Data(bytes: &length, count: 2))
            data.append(pubKey)
        }

        try data.write(to: fileURL, options: .atomic)
    }

    /// Load known identities from disk.
    public func loadKnownIdentities() throws {
        let fileURL = storageDirectory.appendingPathComponent("known_identities.dat")
        guard fileManager.fileExists(atPath: fileURL.path) else { return }

        let data = try Data(contentsOf: fileURL)
        var offset = 0

        while offset + 2 <= data.count {
            let length = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2
            guard offset + length <= data.count else { break }

            let pubKeyData = data[offset..<(offset + length)]
            if let identity = try? RNSIdentity(publicKeyBytes: Data(pubKeyData)) {
                knownIdentities[identity.hash] = identity
            }
            offset += length
        }
    }

    // MARK: - Private

    private func ensureDirectory() throws {
        if !fileManager.fileExists(atPath: storageDirectory.path) {
            try fileManager.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
        }
    }
}
