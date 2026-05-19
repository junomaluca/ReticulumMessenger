// SPDX-License-Identifier: MIT
// ReticulumMessenger — StorageService.swift
// Local persistence for conversations, settings, and interface configs.

import Foundation
import CryptoKit
import CommonCrypto
import ReticulumKit

/// Manages local persistence of app data using UserDefaults and file storage.
final class StorageService {

    // MARK: - Constants

    private let conversationsKey = "saved_conversations"
    private let displayNameKey = "user_display_name"
    private let interfaceConfigsKey = "interface_configs"
    private let defaults = UserDefaults.standard

    private var storageURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("ReticulumMessenger")
    }

    // MARK: - Initialization

    init() {
        ensureStorageDirectory()
    }

    // MARK: - Conversations

    func saveConversations(_ conversations: [Conversation]) {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        let url = storageURL.appendingPathComponent("conversations.json")
        try? data.write(to: url, options: .atomic)
    }

    func loadConversations() -> [Conversation] {
        let url = storageURL.appendingPathComponent("conversations.json")
        guard let data = try? Data(contentsOf: url),
              let conversations = try? JSONDecoder().decode([Conversation].self, from: data) else {
            return []
        }
        return conversations
    }

    // MARK: - Display Name

    func saveDisplayName(_ name: String?) {
        defaults.set(name, forKey: displayNameKey)
    }

    func loadDisplayName() -> String? {
        defaults.string(forKey: displayNameKey)
    }

    // MARK: - Interface Configs

    func saveInterfaceConfigs(_ configs: [RNSInterfaceConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        defaults.set(data, forKey: interfaceConfigsKey)
    }

    func loadInterfaceConfigs() -> [RNSInterfaceConfig] {
        guard let data = defaults.data(forKey: interfaceConfigsKey),
              let configs = try? JSONDecoder().decode([RNSInterfaceConfig].self, from: data) else {
            return []
        }
        return configs
    }

    // MARK: - Identity Export/Import

    func exportIdentity(password: String) throws -> URL {
        let identityURL = storageURL.appendingPathComponent("identity.key")
        guard FileManager.default.fileExists(atPath: identityURL.path) else {
            throw StorageError.noIdentity
        }

        let identityData = try Data(contentsOf: identityURL)

        // Encrypt with password-derived key using CryptoKit
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = deriveKey(password: password, salt: salt)

        let sealedBox = try ChaChaPoly.seal(identityData, using: key)
        let combined = sealedBox.combined

        // Package: magic bytes + version + salt + encrypted data
        var exportData = Data("RNID".utf8)  // magic
        exportData.append(UInt8(1))          // version
        exportData.append(salt)
        exportData.append(combined)

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-backup.rnid")
        try exportData.write(to: exportURL)
        return exportURL
    }

    func importIdentity(from url: URL, password: String) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw StorageError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let data = try Data(contentsOf: url)

        // Validate magic bytes and minimum size (4 magic + 1 ver + 16 salt + 28 min ChaChaPoly)
        guard data.count >= 49,
              String(data: data.prefix(4), encoding: .utf8) == "RNID" else {
            throw StorageError.invalidBackup
        }

        let version = data[4]
        guard version == 1 else {
            throw StorageError.unsupportedVersion
        }

        let salt = data[5..<21]
        let encrypted = data[21...]

        let key = deriveKey(password: password, salt: Data(salt))

        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: encrypted)
            let decrypted = try ChaChaPoly.open(sealedBox, using: key)

            // Write to identity file
            let identityURL = storageURL.appendingPathComponent("identity.key")
            try decrypted.write(to: identityURL, options: .atomic)
        } catch {
            throw StorageError.wrongPassword
        }
    }

    private func deriveKey(password: String, salt: Data) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derivedBytes = [UInt8](repeating: 0, count: 32)
        let status = passwordData.withUnsafeBytes { pwBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                    passwordData.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    100_000, // 100k iterations
                    &derivedBytes,
                    32
                )
            }
        }
        guard status == kCCSuccess else {
            // Fallback: should never happen with valid inputs
            return SymmetricKey(data: Data(SHA256.hash(data: passwordData + salt)))
        }
        return SymmetricKey(data: Data(derivedBytes))
    }

    // MARK: - Private

    private func ensureStorageDirectory() {
        try? FileManager.default.createDirectory(
            at: storageURL,
            withIntermediateDirectories: true
        )
    }
}

// MARK: - Errors

enum StorageError: Error, LocalizedError {
    case noIdentity
    case accessDenied
    case invalidBackup
    case unsupportedVersion
    case wrongPassword

    var errorDescription: String? {
        switch self {
        case .noIdentity: return "No identity found to export"
        case .accessDenied: return "Cannot access the selected file"
        case .invalidBackup: return "Not a valid identity backup file"
        case .unsupportedVersion: return "Backup file version not supported"
        case .wrongPassword: return "Incorrect password"
        }
    }
}
