// SPDX-License-Identifier: MIT
// ReticulumMessenger — StorageService.swift
// Local persistence for conversations, settings, and interface configs.

import Foundation
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

    // MARK: - Private

    private func ensureStorageDirectory() {
        try? FileManager.default.createDirectory(
            at: storageURL,
            withIntermediateDirectories: true
        )
    }
}
