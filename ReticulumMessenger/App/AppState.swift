// SPDX-License-Identifier: MIT
// ReticulumMessenger — AppState.swift
// Central app state coordinating the Reticulum stack, LXMF router, and UI.

import SwiftUI
import Combine
import Network
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

    // RNode
    @Published var connectedRNode: RNodeInfo?
    @Published var isRNodeScanning = false

    // Announce stream
    @Published var announceStream: [AnnounceEntry] = []

    // Diagnostics
    @Published var packetDiagnostics: String = ""
    @Published var probeResult: String = ""

    /// Per-interface debug capture: recent outbound packet hex (pre-framing).
    /// Keyed by interface name. Updated by the periodic refresh loop.
    @Published var recentOutboundByInterface: [String: [String]] = [:]

    /// Last N LXMF send/recv events with sizes + errors. Refreshed periodically.
    @Published var recentMessageLog: [LXMRouter.LogEntry] = []

    // Settings
    @Published var autoAnnounceEnabled = false
    @Published var transportModeEnabled = false
    @Published var propagationNodeEnabled = false
    @Published var locationSharingEnabled = false
    @Published var autoPublishDiagnosticsEnabled = false
    @Published var streamDiagnosticsEnabled = false

    /// Most recent diagnostic publish URL (paste.rs) and its timestamp.
    @Published var lastDiagnosticsURL: String?
    @Published var lastDiagnosticsAt: Date?
    /// ntfy.sh topic used for streaming. Generated once per install.
    @Published var ntfyTopic: String = ""
    @Published var lastStreamAt: Date?

    // Rust engine status (mirrored from RustEngine for the UI).
    @Published var rustEngineEnabled: Bool = false
    @Published var rustEngineStarted: Bool = false
    @Published var rustLxmfAddress: String = ""
    @Published var rustIdentityHash: String = ""
    @Published var rustEngineError: String?
    @Published var rustRecentInbound: [String] = []   // newest last, max 20
    @Published var rustHubOnline: Int32 = -1          // 1 online, 0 offline, -1 unknown
    @Published var rustOutboundLog: [String] = []     // recent outbound LXMF sends (newest last)

    /// Lazily-created Rust engine. nil until the user enables it.
    private(set) var rustEngine: RustEngine?

    // MARK: - Services

    private(set) var messengerService: MessengerService?
    private(set) var storageService: StorageService?
    private(set) var telemetryService: TelemetryService?

    // MARK: - Protocol Layer

    private var reticulum: Reticulum?
    private var lxmRouter: LXMRouter?
    private var rnodeInterface: RNodeInterface?
    private var autoAnnounceTimer: Timer?
    private var autoPublishTimer: Timer?
    private var streamTimer: Timer?
    /// Auto-publish cadence in seconds (paste.rs, persistent URL).
    static let autoPublishInterval: TimeInterval = 60
    /// Streaming cadence in seconds (ntfy.sh push to subscribed listener).
    static let streamInterval: TimeInterval = 10
    private var periodicUpdateTask: Task<Void, Never>?
    private var rnodeScanTask: Task<Void, Never>?
    private var discoveredRNodeIds: Set<UUID> = []
    private var savedInterfaceConfigs: [RNSInterfaceConfig] = []
    private var telemetryCancellable: AnyCancellable?

    /// Peers discovered via announce callbacks (keyed by destination hash).
    /// Kept separate so the periodic LXMF router refresh doesn't overwrite them.
    private var announceDiscoveredPeers: [Data: PeerInfo] = [:]

    // MARK: - iOS Resilience (from runcore & Columba-iOS research)

    /// Network path monitor — detects connectivity changes (WiFi ↔ cellular, etc.)
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.reticulummessenger.pathmonitor")

    /// Whether the app is currently in the foreground.
    private var isInForeground = true

    /// Timestamp of last background transition (for resume delay calculation).
    private var lastBackgroundTime: Date?

    // MARK: - Initialization

    func initialize() async {
        guard !isInitialized else { return }

        // Initialize storage
        let storage = StorageService()
        self.storageService = storage

        // Initialize telemetry and forward its changes so SwiftUI views update
        let telemetry = TelemetryService()
        self.telemetryService = telemetry
        telemetryCancellable = telemetry.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }

        // Load saved conversations and settings
        conversations = storage.loadConversations()
        let savedInterfaces = storage.loadInterfaceConfigs()
        self.savedInterfaceConfigs = savedInterfaces

        // Load user preferences
        loadUserPreferences()

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

        // Request notification permission
        NotificationService.shared.registerCategories()
        _ = await NotificationService.shared.requestPermission()

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

            // Register delivery update handler to track sent/failed states
            await router.onDeliveryUpdate { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.handleDeliveryUpdate(update)
                }
            }

            // Register announce handler
            await rns.transport.onAnnounce { [weak self] hash, name, appData in
                Task { @MainActor [weak self] in
                    self?.handleAnnounce(hash: hash, name: name, appData: appData)
                }
            }

            networkStatus = .connected
            isInitialized = true

            // Start interface health watchdog (from runcore research)
            await rns.transport.startWatchdog()

            // Start periodic UI updates
            startPeriodicUpdates()

            // Start network path monitoring (from Columba-iOS research)
            startPathMonitor()

            // Set up app lifecycle observers for suspend/resume handling
            setupLifecycleObservers()

            // Start telemetry if enabled
            if locationSharingEnabled {
                telemetry.startLocationUpdates()
            }
            telemetry.startPeriodicTelemetry()

            // Start auto-announce if enabled
            if autoAnnounceEnabled {
                startAutoAnnounce()
            }

            // Start auto-publish if enabled
            if autoPublishDiagnosticsEnabled {
                startAutoPublishDiagnostics()
            }

            // Start streaming if enabled
            if streamDiagnosticsEnabled {
                startStreamDiagnostics()
            }

            // Auto-start Rust engine if user enabled it previously
            if rustEngineEnabled {
                startRustEngine()
            }

            // Activate transport mode if enabled
            if transportModeEnabled {
                await rns.transport.setTransportEnabled(true)
            }

            // Activate propagation node if enabled
            if propagationNodeEnabled {
                await router.setPropagationNode(true)
            }

        } catch {
            networkStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Messaging

    func sendMessage(content: String, to destinationHash: Data) async throws {
        if rustEngineEnabled, rustEngineStarted, let engine = rustEngine, let src = engine.lxmfHash {
            let message = LXMessage(
                sourceHash: src,
                destinationHash: destinationHash,
                content: content
            )
            let localId = message.id
            addMessageToConversation(message)
            NotificationService.shared.playMessageSentHaptic()
            let destHex = destinationHash.map { String(format: "%02x", $0) }.joined()
            do {
                _ = try engine.sendText(to: destinationHash, content: content)
                appendRustOutbound("text \(content.count)B → \(String(destHex.prefix(16)))")
                // Rust engine queued + transmitted successfully — flip the
                // local ChatMessage from .pending (clock) to .sent (check).
                // The Rust engine doesn't yet surface per-message LRPROOF
                // callbacks to us; "delivered" requires that hook.
                updateMessageState(lxmfId: localId, to: .sent)
            } catch {
                appendRustOutbound("text → \(String(destHex.prefix(16))) FAIL: \(error.localizedDescription)")
                updateMessageState(lxmfId: localId, to: .failed)
                throw error
            }
            return
        }

        guard let router = lxmRouter, let rns = reticulum else { return }

        let identity = try await rns.getLocalIdentity()
        let message = LXMessage(
            sourceHash: identity.hash,
            destinationHash: destinationHash,
            content: content
        )

        // Add to conversation immediately (optimistic)
        addMessageToConversation(message)

        // Haptic feedback
        NotificationService.shared.playMessageSentHaptic()

        // Send via LXMF router
        _ = try await router.send(message)
    }

    func sendAttachment(data: Data, mimeType: String, filename: String?, to destinationHash: Data) async throws {
        if rustEngineEnabled, rustEngineStarted, let engine = rustEngine, let src = engine.lxmfHash {
            var message = LXMessage(
                sourceHash: src,
                destinationHash: destinationHash,
                content: filename ?? "Attachment"
            )
            message.addAttachment(LXMFAttachment(data: data, mimeType: mimeType, filename: filename))
            let localId = message.id
            addMessageToConversation(message)
            NotificationService.shared.playMessageSentHaptic()
            let destHex = destinationHash.map { String(format: "%02x", $0) }.joined()
            do {
                _ = try engine.sendAttachment(
                    to: destinationHash, data: data, mimeType: mimeType,
                    filename: filename ?? "attachment.bin",
                    body: filename ?? "Attachment"
                )
                appendRustOutbound("attach \(filename ?? "?") \(data.count)B → \(String(destHex.prefix(16)))")
                updateMessageState(lxmfId: localId, to: .sent)
            } catch {
                appendRustOutbound("attach → \(String(destHex.prefix(16))) FAIL: \(error.localizedDescription)")
                updateMessageState(lxmfId: localId, to: .failed)
                throw error
            }
            return
        }

        guard let router = lxmRouter, let rns = reticulum else { return }

        let identity = try await rns.getLocalIdentity()
        var message = LXMessage(
            sourceHash: identity.hash,
            destinationHash: destinationHash,
            content: filename ?? "Attachment"
        )
        message.addAttachment(LXMFAttachment(data: data, mimeType: mimeType, filename: filename))

        addMessageToConversation(message)
        NotificationService.shared.playMessageSentHaptic()
        _ = try await router.send(message)
    }

    func createConversation(with destinationHash: Data, name: String?) {
        guard !conversations.contains(where: { !$0.isGroup && $0.peerHash == destinationHash }) else { return }

        let conversation = Conversation(
            peerHash: destinationHash,
            displayName: name,
            messages: [],
            lastActivity: Date()
        )
        conversations.insert(conversation, at: 0)
        storageService?.saveConversations(conversations)
    }

    // MARK: - Group Messaging

    /// Custom LXMF field ID for group identification.
    static let groupFieldId: UInt8 = 0x10

    func createGroupConversation(name: String, members: [PeerInfo]) {
        let groupId = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let groupIdData = Data(groupId)
        let memberHashes = members.map { $0.destinationHash }

        let conversation = Conversation(
            peerHash: groupIdData,
            displayName: name,
            messages: [],
            lastActivity: Date(),
            isGroup: true,
            groupId: groupIdData,
            memberHashes: memberHashes
        )
        conversations.insert(conversation, at: 0)
        storageService?.saveConversations(conversations)
    }

    func sendGroupMessage(content: String, groupConversation: Conversation) async throws {
        guard let router = lxmRouter, let rns = reticulum else { return }
        guard groupConversation.isGroup, let groupId = groupConversation.groupId else { return }

        let identity = try await rns.getLocalIdentity()
        let senderName = storageService?.loadDisplayName()

        // Fan-out: send individual messages to each group member
        for memberHash in groupConversation.memberHashes {
            var message = LXMessage(
                sourceHash: identity.hash,
                destinationHash: memberHash,
                content: content,
                fields: [Self.groupFieldId: .binary(groupId)]
            )
            message.sourceName = senderName
            _ = try? await router.send(message)
        }

        // Add to local group conversation
        let chatMessage = ChatMessage(
            content: content,
            isIncoming: false,
            state: .sent,
            senderName: senderName
        )
        if let idx = conversations.firstIndex(where: { $0.groupId == groupId }) {
            conversations[idx].messages.append(chatMessage)
            conversations[idx].lastActivity = Date()
        }
        storageService?.saveConversations(conversations)
        NotificationService.shared.playMessageSentHaptic()
    }

    // MARK: - Interface Management

    func addTCPInterface(name: String, host: String, port: UInt16) async throws {
        guard let rns = reticulum else { return }
        // connectTCP registers the interface with transport before connecting,
        // so even if connect() fails the interface will retry in the background.
        try? await rns.connectTCP(name: name, host: host, port: port)
        savedInterfaceConfigs.append(RNSInterfaceConfig(name: name, type: .tcpClient, host: host, port: port))
        await refreshInterfaces()
        saveCurrentInterfaces()
    }

    func addUDPInterface(name: String, host: String?, port: UInt16, listenPort: UInt16) async throws {
        guard let rns = reticulum else { return }
        let udp = UDPInterface(name: name, host: host, port: port, listenPort: listenPort)
        await rns.transport.registerInterface(udp)
        try? await udp.connect()
        savedInterfaceConfigs.append(RNSInterfaceConfig(name: name, type: .udp, host: host, port: port))
        await refreshInterfaces()
        saveCurrentInterfaces()
    }

    func deleteConversation(_ conversationId: UUID) {
        conversations.removeAll { $0.id == conversationId }
        storageService?.saveConversations(conversations)
    }

    // MARK: - Interface Management (Edit/Delete)

    func deleteInterface(named name: String) async {
        // Remove from transport layer
        if let rns = reticulum {
            await rns.transport.removeInterface(name: name)
        }
        // Remove from saved configs
        savedInterfaceConfigs.removeAll { $0.name == name }
        saveCurrentInterfaces()
        await refreshInterfaces()
    }

    func savedInterfaceConfig(named name: String) -> RNSInterfaceConfig? {
        savedInterfaceConfigs.first { $0.name == name }
    }

    func updateInterface(oldName: String, name: String, host: String, port: UInt16, type: RNSInterfaceConfig.InterfaceType) async throws {
        // Remove old
        await deleteInterface(named: oldName)
        // Add new
        switch type {
        case .tcpClient:
            try await addTCPInterface(name: name, host: host, port: port)
        case .udp:
            try await addUDPInterface(name: name, host: host, port: port, listenPort: port)
        default:
            break
        }
    }

    // MARK: - RNode Management

    func startRNodeScan(onDiscover: @escaping (RNodeInterface.DiscoveredRNode) -> Void) {
        let rnode = RNodeInterface(name: "RNode")
        self.rnodeInterface = rnode
        discoveredRNodeIds.removeAll()
        rnode.startScanning()
        isRNodeScanning = true

        rnodeScanTask?.cancel()
        rnodeScanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.isRNodeScanning else { break }
                let devices = rnode.discoveredDevices
                for device in devices {
                    if !self.discoveredRNodeIds.contains(device.id) {
                        self.discoveredRNodeIds.insert(device.id)
                        onDiscover(device)
                    }
                }
            }
        }
    }

    func stopRNodeScan() {
        rnodeScanTask?.cancel()
        rnodeScanTask = nil
        rnodeInterface?.stopScanning()
        isRNodeScanning = false
    }

    func connectRNode(deviceId: UUID, name: String) async throws {
        guard let rnode = rnodeInterface else { return }
        try await rnode.connect(deviceId: deviceId)

        connectedRNode = RNodeInfo(
            name: name,
            deviceId: deviceId,
            config: .balanced,
            radioOnline: true
        )

        // Register with transport
        if let rns = reticulum {
            await rns.transport.registerInterface(rnode)
        }

        NotificationService.shared.playConnectionHaptic()
        await refreshInterfaces()
    }

    func disconnectRNode() async {
        await rnodeInterface?.disconnect()
        connectedRNode = nil
        await refreshInterfaces()
    }

    func configureRNode(_ config: RNodeConfig) async {
        await rnodeInterface?.configure(config)
        connectedRNode?.config = config
    }

    // MARK: - Auto-Announce

    func startAutoAnnounce(interval: TimeInterval = 300) {
        stopAutoAnnounce()
        autoAnnounceEnabled = true
        saveUserPreferences()

        // Announce immediately
        Task {
            let name = storageService?.loadDisplayName()
            let loc = telemetryService?.currentLocation
            try? await messengerService?.announce(displayName: name, latitude: loc?.latitude, longitude: loc?.longitude)
        }

        autoAnnounceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let name = self.storageService?.loadDisplayName()
                let loc = self.telemetryService?.currentLocation
                try? await self.messengerService?.announce(displayName: name, latitude: loc?.latitude, longitude: loc?.longitude)
            }
        }
    }

    func stopAutoAnnounce() {
        autoAnnounceTimer?.invalidate()
        autoAnnounceTimer = nil
        autoAnnounceEnabled = false
        saveUserPreferences()
    }

    // MARK: - Rust Engine

    /// Toggle the experimental Rust LXMF engine. Sends/receives via the
    /// official Rusticulum + LXMF-rust impls when ON. Pure-Swift stack
    /// continues to run alongside it for backwards compatibility.
    func setRustEngine(_ enabled: Bool) {
        rustEngineEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "rustEngineEnabled")
        if enabled {
            startRustEngine()
        } else {
            // We don't tear down the Rust client mid-session; toggling off
            // simply stops the app from offering it as a send/receive engine.
            rustEngineStarted = false
        }
    }

    private func startRustEngine() {
        if rustEngine == nil {
            rustEngine = RustEngine()
        }
        guard let engine = rustEngine else { return }
        let name = storageService?.loadDisplayName() ?? "Reticulum Messenger"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try engine.start(displayName: name)
                await MainActor.run {
                    self?.rustEngineStarted = true
                    self?.rustLxmfAddress = engine.lxmfHash?
                        .map { String(format: "%02x", $0) }.joined() ?? ""
                    self?.rustIdentityHash = engine.identityHash?
                        .map { String(format: "%02x", $0) }.joined() ?? ""
                    self?.rustEngineError = nil
                }
                engine.setDeliveryHandler { [weak self] msg in
                    Task { @MainActor in
                        guard let self else { return }
                        let (parsedFields, parsedAttachments) = Self.parseRustFields(msg.fieldsRaw)
                        let prefix = msg.fieldsRaw.prefix(64).map { String(format: "%02x", $0) }.joined()
                        NSLog("[RustEngine] inbound fieldsRaw bytes=\(msg.fieldsRaw.count) head=\(prefix) parsedAttachments=\(parsedAttachments.count) parsedFields=\(parsedFields.keys.map { String(format: "0x%02x", $0) })")
                        var lxm = LXMessage(
                            id: msg.messageHash,
                            sourceHash: msg.sourceHash,
                            destinationHash: msg.destinationHash,
                            content: msg.content,
                            title: msg.title.isEmpty ? nil : msg.title,
                            timestamp: msg.timestamp,
                            method: .direct,
                            fields: parsedFields
                        )
                        lxm.attachments = parsedAttachments
                        self.handleReceivedMessage(lxm)

                        let attLabel = parsedAttachments.isEmpty
                            ? ""
                            : " [+\(parsedAttachments.count) attachment\(parsedAttachments.count == 1 ? "" : "s")]"
                        let line = "\(msg.title.isEmpty ? "(no title)" : msg.title): \(msg.content.prefix(80))\(attLabel)"
                        self.rustRecentInbound.append(line)
                        if self.rustRecentInbound.count > 20 {
                            self.rustRecentInbound.removeFirst()
                        }
                    }
                }
                engine.setAnnounceHandler { [weak self] destHash, name in
                    Task { @MainActor in
                        self?.handleAnnounce(hash: destHash, name: name, appData: name)
                    }
                }
                // Re-announce on every interface up-edge + every 10 min,
                // so the hub TCP socket finishing its handshake after our
                // initial one-shot announce still gets us on the network.
                engine.publish(refreshSeconds: 600)
                engine.announce()

                // Probe the testnet hub interface state on a slow timer so
                // we can confirm WAN connectivity in the diagnostics stream.
                // 5s startup grace + repeat every 15s.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    while let self, self.rustEngineEnabled, self.rustEngineStarted {
                        let s = engine.interfaceOnline("Community Hub Testnet")
                        self.rustHubOnline = s
                        if s == 1 {
                            self.rustEngineError = nil
                        } else if s == 0 {
                            self.rustEngineError = "hub offline"
                        }
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                    }
                }

            } catch {
                await MainActor.run {
                    self?.rustEngineStarted = false
                    self?.rustEngineError = error.localizedDescription
                }
            }
        }
    }

    /// Send a text message via the Rust engine. Throws on misconfiguration.
    func rustSendText(to destHex: String, content: String, title: String = "") async throws {
        guard let engine = rustEngine, rustEngineStarted else {
            throw RustEngineError.sendFailed("Rust engine not started")
        }
        guard let dest = Self.hexToData(destHex), dest.count == 16 else {
            throw RustEngineError.invalidArgument("Invalid 32-char hex address")
        }
        _ = try engine.sendText(to: dest, content: content, title: title)
    }

    /// Send a binary attachment via the Rust engine.
    func rustSendAttachment(to destHex: String, data: Data, mime: String, filename: String,
                            title: String = "", body: String = "") async throws {
        guard let engine = rustEngine, rustEngineStarted else {
            throw RustEngineError.sendFailed("Rust engine not started")
        }
        guard let dest = Self.hexToData(destHex), dest.count == 16 else {
            throw RustEngineError.invalidArgument("Invalid 32-char hex address")
        }
        _ = try engine.sendAttachment(to: dest, data: data, mimeType: mime,
                                      filename: filename, title: title, body: body)
    }

    private func appendRustOutbound(_ line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        rustOutboundLog.append("\(timestamp) \(line)")
        if rustOutboundLog.count > 20 {
            rustOutboundLog.removeFirst()
        }
    }

    /// Decode the raw LXMF fields blob handed to us by the Rust engine.
    /// The blob is the msgpack-encoded fields map: `{ field_id: value, ... }`.
    /// Returns the non-attachment fields (so existing code paths keep
    /// working) and any binary attachments separately, since the
    /// ChatMessage / MessageBubble surfaces attachments via a dedicated
    /// property — packing them back into `fields` would hide them.
    private static func parseRustFields(_ raw: Data) -> ([UInt8: MessagePackValue], [LXMFAttachment]) {
        guard !raw.isEmpty else { return ([:], []) }
        guard let value = try? MessagePackDecoder.decode(raw),
              case .map(let pairs) = value else {
            return ([:], [])
        }
        var fields: [UInt8: MessagePackValue] = [:]
        var attachments: [LXMFAttachment] = []
        for (key, val) in pairs {
            guard let keyNum = key.intValue else { continue }
            let fieldType = UInt8(truncatingIfNeeded: keyNum)
            switch fieldType {
            case LXMessage.FieldType.fileAttachments.rawValue,
                 LXMessage.FieldType.image.rawValue,
                 LXMessage.FieldType.audio.rawValue:
                if let att = LXMFAttachment.fromMessagePack(val) {
                    attachments.append(att)
                }
            default:
                fields[fieldType] = val
            }
        }
        return (fields, attachments)
    }

    private static func hexToData(_ hex: String) -> Data? {
        let s = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.count % 2 == 0, s.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        var out = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }

    // MARK: - Auto-publish Diagnostics

    func setAutoPublishDiagnostics(_ enabled: Bool) {
        autoPublishDiagnosticsEnabled = enabled
        saveUserPreferences()
        if enabled {
            startAutoPublishDiagnostics()
        } else {
            stopAutoPublishDiagnostics()
        }
    }

    private func startAutoPublishDiagnostics() {
        stopAutoPublishDiagnostics()
        // Fire once immediately so the latest URL is available right away,
        // then on the interval.
        publishDiagnosticsNow()
        autoPublishTimer = Timer.scheduledTimer(withTimeInterval: Self.autoPublishInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishDiagnosticsNow()
            }
        }
    }

    private func stopAutoPublishDiagnostics() {
        autoPublishTimer?.invalidate()
        autoPublishTimer = nil
    }

    // MARK: - Stream Diagnostics (ntfy.sh)

    func setStreamDiagnostics(_ enabled: Bool) {
        streamDiagnosticsEnabled = enabled
        saveUserPreferences()
        if enabled {
            ensureNtfyTopic()
            startStreamDiagnostics()
        } else {
            stopStreamDiagnostics()
        }
    }

    private func ensureNtfyTopic() {
        if ntfyTopic.isEmpty {
            // 22-char base62-ish topic from random bytes.
            let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
            var t = "rmdiag-"
            for _ in 0..<16 { t.append(chars.randomElement()!) }
            ntfyTopic = t
            saveUserPreferences()
        }
    }

    private func startStreamDiagnostics() {
        stopStreamDiagnostics()
        ensureNtfyTopic()
        // Fire once now, then on the interval.
        streamDiagnosticsNow()
        streamTimer = Timer.scheduledTimer(withTimeInterval: Self.streamInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.streamDiagnosticsNow()
            }
        }
    }

    private func stopStreamDiagnostics() {
        streamTimer?.invalidate()
        streamTimer = nil
    }

    func streamDiagnosticsNow() {
        guard !ntfyTopic.isEmpty else { return }
        let report = DiagnosticsService.buildReport(appState: self)
        let topic = ntfyTopic
        Task {
            try? await DiagnosticsService.publishToNtfy(report, topic: topic)
            await MainActor.run { self.lastStreamAt = Date() }
        }
    }

    /// Publish current diagnostics to paste.rs and remember the URL.
    /// Safe to call manually too.
    func publishDiagnosticsNow() {
        let report = DiagnosticsService.buildReport(appState: self)
        Task {
            if let url = try? await DiagnosticsService.publishToPasteRs(report) {
                await MainActor.run {
                    self.lastDiagnosticsURL = url.absoluteString
                    self.lastDiagnosticsAt = Date()
                    self.saveUserPreferences()
                }
            }
        }
    }

    // MARK: - Transport Mode

    func setTransportMode(_ enabled: Bool) async {
        transportModeEnabled = enabled
        if let rns = reticulum {
            await rns.transport.setTransportEnabled(enabled)
        }
        saveUserPreferences()
    }

    // MARK: - Propagation Node

    func setPropagationNode(_ enabled: Bool) async {
        propagationNodeEnabled = enabled
        if let router = lxmRouter {
            await router.setPropagationNode(enabled)
        }
        saveUserPreferences()
    }

    // MARK: - Location Sharing

    func setLocationSharing(_ enabled: Bool) {
        locationSharingEnabled = enabled
        if enabled {
            telemetryService?.startLocationUpdates()
        } else {
            telemetryService?.stopLocationUpdates()
        }
        saveUserPreferences()
    }

    // MARK: - Conversation Pinning

    func togglePin(_ conversationId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        conversations[idx].isPinned.toggle()
        storageService?.saveConversations(conversations)
    }

    // MARK: - Disappearing Messages

    func setDisappearingDuration(_ duration: DisappearingDuration, for conversationId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        conversations[idx].disappearingDuration = duration
        storageService?.saveConversations(conversations)
    }

    // MARK: - Identity Management

    /// Reset the local identity: regenerate keypair, clear stored identity, restart stack.
    func resetIdentity() async {
        // Stop the running stack
        if let rns = reticulum {
            await rns.stop()
        }

        // Delete stored identity file
        if let storage = storageService {
            storage.deleteIdentity()
        }

        // Reset published state
        localIdentityHash = ""
        deliveryHash = ""
        conversations = []
        knownPeers = []
        interfaces = []
        announceStream = []
        networkStatus = .disconnected
        isInitialized = false

        // Reinitialize the stack with a fresh identity
        await initialize()
    }

    // MARK: - Network Diagnostics

    /// Probe a peer's path to diagnose delivery issues.
    func probePeer(_ destinationHash: Data) async {
        guard let rns = reticulum else {
            probeResult = "Reticulum not initialized"
            return
        }
        probeResult = "Probing..."
        let result = await rns.transport.probePath(to: destinationHash)
        probeResult = result
    }

    /// Probe the first known peer (quick diagnostic).
    func probeFirstPeer() async {
        guard let peer = knownPeers.first else {
            probeResult = "No known peers to probe"
            return
        }
        await probePeer(peer.destinationHash)
    }

    // MARK: - Refresh

    func refreshNetworkStatus() async {
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

    // MARK: - Private

    private func handleReceivedMessage(_ message: LXMessage) {
        // Check if this is a group message
        if case .binary(let groupId) = message.fields[Self.groupFieldId] {
            addGroupMessage(message, groupId: groupId)
        } else {
            addMessageToConversation(message)
        }

        // Notification
        let senderName = message.sourceName ?? String(message.sourceHash.map { String(format: "%02x", $0) }.joined().prefix(8))
        NotificationService.shared.showMessageNotification(
            from: senderName,
            content: message.content,
            conversationHash: message.sourceHash.map { String(format: "%02x", $0) }.joined()
        )

        // Haptic
        NotificationService.shared.playMessageReceivedHaptic()

        // Update badge
        let totalUnread = conversations.reduce(0) { $0 + $1.unreadCount }
        NotificationService.shared.updateBadgeCount(totalUnread)
    }

    private func addGroupMessage(_ message: LXMessage, groupId: Data) {
        var chatMessage = ChatMessage(from: message)
        chatMessage.senderName = message.sourceName ?? String(message.sourceHexHash.prefix(8))

        if let idx = conversations.firstIndex(where: { $0.groupId == groupId }) {
            if let interval = conversations[idx].disappearingDuration.interval {
                chatMessage.expiresAt = Date().addingTimeInterval(interval)
            }
            conversations[idx].messages.append(chatMessage)
            conversations[idx].lastActivity = Date()
            let conv = conversations.remove(at: idx)
            if conv.isPinned {
                conversations.insert(conv, at: 0)
            } else {
                let firstUnpinnedIdx = conversations.firstIndex(where: { !$0.isPinned }) ?? conversations.count
                conversations.insert(conv, at: firstUnpinnedIdx)
            }
            // Add sender to members if not already present
            if !conversations.first(where: { $0.groupId == groupId })!.memberHashes.contains(message.sourceHash) {
                if let i = conversations.firstIndex(where: { $0.groupId == groupId }) {
                    conversations[i].memberHashes.append(message.sourceHash)
                }
            }
        }
        // If no matching group, this is a group we haven't joined — ignore for now

        storageService?.saveConversations(conversations)
    }

    private func handleAnnounce(hash: Data, name: String?, appData: String?) {
        let hexHash = hash.map { String(format: "%02x", $0) }.joined()

        // Display name + optional location is extracted from the announce app_data.
        // Three encodings are seen in the wild:
        //  1. Our legacy format: "displayName\x1Elat,lon" (UTF-8 string).
        //  2. Our legacy: bare "displayName" (UTF-8 string).
        //  3. Official LXMF v0.5.0+: msgpack array `[display_name_bytes, stamp_cost, supported_features?, ...]`
        //     — locations are NOT in the announce; they ride on LXMF telemetry messages.
        var displayName = name
        if let raw = appData {
            let bytes = Data(raw.utf8)
            // Detect LXMF v0.5.0+ msgpack format (first byte is a fixed-array or array16 marker).
            // 0x90..0x9f = fixed-length array, 0xdc = array16.
            if let first = bytes.first, (first >= 0x90 && first <= 0x9f) || first == 0xdc {
                if let value = try? MessagePackDecoder.decode(bytes),
                   case .array(let arr) = value,
                   !arr.isEmpty {
                    if let dnBytes = arr[0].dataValue, let s = String(data: dnBytes, encoding: .utf8) {
                        displayName = s.replacingOccurrences(of: "\u{0000}", with: "")
                    } else if let s = arr[0].stringValue {
                        displayName = s
                    }
                }
            } else if let sep = raw.firstIndex(of: "\u{1E}") {
                displayName = String(raw[raw.startIndex..<sep])
                let locPart = String(raw[raw.index(after: sep)...])
                let parts = locPart.split(separator: ",")
                if parts.count == 2,
                   let lat = Double(parts[0]),
                   let lon = Double(parts[1]) {
                    telemetryService?.updatePeerLocation(
                        hash: hash, latitude: lat, longitude: lon,
                        displayName: displayName
                    )
                }
            } else {
                displayName = raw
            }
        }

        // Always register as a known peer (announce-discovered).
        // This dict is merged with LXMF router peers in periodic updates
        // instead of being overwritten.
        let peerInfo = PeerInfo(
            destinationHash: hash,
            displayName: displayName ?? hexHash,
            lastSeen: Date()
        )
        announceDiscoveredPeers[hash] = peerInfo

        // Update knownPeers immediately for UI responsiveness
        if let existing = knownPeers.firstIndex(where: { $0.destinationHash == hash }) {
            knownPeers[existing] = peerInfo
        } else {
            knownPeers.append(peerInfo)
        }

        // Announce type: all ReticulumMessenger announces are LXMF since
        // they come from lxmf.delivery destinations. The appData contains
        // a display name, not the app name string.
        let type: AnnounceEntry.AnnounceType = .lxmf

        let entry = AnnounceEntry(
            hash: hexHash,
            displayName: displayName,
            type: type,
            timestamp: Date(),
            appData: appData,
            destinationHash: hash
        )

        announceStream.insert(entry, at: 0)

        // Keep only last 200 announces
        if announceStream.count > 200 {
            announceStream = Array(announceStream.prefix(200))
        }
    }

    /// Update an outgoing ChatMessage's state by its `lxmfId`. Used by the
    /// Rust engine send path which doesn't go through LXMRouter's
    /// DeliveryUpdate pipeline. Walks every conversation since we don't
    /// know which one the message landed in.
    private func updateMessageState(lxmfId: Data, to newState: ChatMessage.MessageState) {
        for i in conversations.indices {
            if let j = conversations[i].messages.firstIndex(where: { $0.lxmfId == lxmfId }) {
                conversations[i].messages[j].state = newState
                storageService?.saveConversations(conversations)
                return
            }
        }
    }

    private func handleDeliveryUpdate(_ update: LXMRouter.DeliveryUpdate) {
        let targetState: ChatMessage.MessageState
        switch update.state {
        case .sent: targetState = .sent
        case .delivered: targetState = .delivered
        case .failed: targetState = .failed
        default: return
        }

        // Find the message by lxmfId across all conversations and update its state
        for i in conversations.indices {
            if let j = conversations[i].messages.firstIndex(where: { $0.lxmfId == update.messageId }) {
                conversations[i].messages[j].state = targetState
                storageService?.saveConversations(conversations)
                return
            }
        }
    }

    private func addMessageToConversation(_ message: LXMessage) {
        let peerHash = message.isIncoming ? message.sourceHash : message.destinationHash
        var chatMessage = ChatMessage(from: message)

        if let idx = conversations.firstIndex(where: { $0.peerHash == peerHash }) {
            // Apply disappearing duration
            if let interval = conversations[idx].disappearingDuration.interval {
                chatMessage.expiresAt = Date().addingTimeInterval(interval)
            }
            conversations[idx].messages.append(chatMessage)
            conversations[idx].lastActivity = Date()
            // Move to top of its section (pinned stay above unpinned)
            let conv = conversations.remove(at: idx)
            if conv.isPinned {
                conversations.insert(conv, at: 0)
            } else {
                let firstUnpinnedIdx = conversations.firstIndex(where: { !$0.isPinned }) ?? conversations.count
                conversations.insert(conv, at: firstUnpinnedIdx)
            }
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
        // Collect outbound debug captures from TCP interfaces.
        var captures: [String: [String]] = [:]
        for iface in ifaces {
            if let tcp = iface as? TCPClientInterface {
                captures[tcp.name] = tcp.recentOutboundHex
            }
        }
        recentOutboundByInterface = captures
    }

    private func startPeriodicUpdates() {
        periodicUpdateTask?.cancel()
        periodicUpdateTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                await refreshInterfaces()
                if let router = lxmRouter {
                    // Merge LXMF router peers with announce-discovered peers
                    // so announces don't get wiped every refresh cycle.
                    let routerPeers = await router.knownPeers()
                    var merged: [Data: PeerInfo] = announceDiscoveredPeers
                    for rp in routerPeers {
                        let pi = PeerInfo(from: rp)
                        // Router info takes priority for display name if present
                        if let existing = merged[pi.destinationHash] {
                            merged[pi.destinationHash] = PeerInfo(
                                destinationHash: pi.destinationHash,
                                displayName: pi.displayName.isEmpty ? existing.displayName : pi.displayName,
                                lastSeen: max(pi.lastSeen, existing.lastSeen)
                            )
                        } else {
                            merged[pi.destinationHash] = pi
                        }
                    }
                    knownPeers = Array(merged.values).sorted { $0.lastSeen > $1.lastSeen }
                }
                if let rns = reticulum {
                    let stats = await rns.statistics()
                    if stats.onlineInterfaces > 0 {
                        networkStatus = .connected
                    } else {
                        networkStatus = .connecting
                    }
                    var diag = "IN  rx:\(stats.packetsReceived) fail:\(stats.packetsParseFailed) dup:\(stats.packetsDeduplicated)"
                    diag += "\nANN in:\(stats.announcesProcessed) out:\(stats.announcesSent)"
                    diag += "\nPATH req-in:\(stats.pathRequestsReceived) rsp-out:\(stats.pathResponsesSent) req-out:\(stats.pathRequestsSent)"
                    diag += "\n     dest:\(stats.registeredDestinations) known:\(stats.knownPaths)"
                    diag += "\nOUT tx:\(stats.packetsSent) err:\(stats.sendErrors)"
                    diag += "\nMSG local:\(stats.dataPacketsForLocal) unmatched:\(stats.dataPacketsUnmatched)"
                    if let sendErr = stats.lastSendError {
                        diag += "\ntx-err: \(sendErr)"
                    }
                    if let router = lxmRouter {
                        let lxSendAttempts = await router.sendAttempts
                        let lxSendOk = await router.sendSuccesses
                        let lxSendFail = await router.sendFailures
                        let lxSendErr = await router.lastSendError
                        let lxPkts = await router.packetsReceived
                        let lxFail = await router.deserializeFailures
                        let lxOk = await router.messagesDelivered
                        let lxErr = await router.lastDeserializeError
                        diag += "\nLXMF send:\(lxSendAttempts) ok:\(lxSendOk) fail:\(lxSendFail)"
                        if let err = lxSendErr {
                            diag += "\nsend-err: \(err)"
                        }
                        diag += "\nLXMF recv:\(lxPkts) ok:\(lxOk) fail:\(lxFail)"
                        if let err = lxErr {
                            diag += "\nrecv-err: \(err)"
                        }
                        recentMessageLog = await router.messageLog
                    }
                    packetDiagnostics = diag
                }

                // Update RNode stats
                if let rnode = rnodeInterface, connectedRNode != nil {
                    let stats = rnode.radioStats
                    connectedRNode?.lastRSSI = stats.rssi
                    connectedRNode?.lastSNR = stats.snr
                    connectedRNode?.batteryLevel = stats.battery
                    connectedRNode?.radioOnline = stats.online
                    connectedRNode?.firmwareVersion = stats.firmwareVersion
                }

                // Purge expired disappearing messages
                purgeExpiredMessages()
            }
        }
    }

    // MARK: - App Lifecycle (iOS Resilience)

    /// Set up observers for app lifecycle transitions.
    /// Critical for iOS: sockets go half-dead after suspend/resume.
    /// Learned from runcore: ALWAYS force-reconnect TCP on resume.
    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppWillResignActive()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleAppDidBecomeActive()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppDidEnterBackground()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleAppWillEnterForeground()
            }
        }
    }

    private func handleAppWillResignActive() {
        isInForeground = false
        lastBackgroundTime = Date()
    }

    private func handleAppDidEnterBackground() {
        // Stop the interface watchdog to save battery
        Task {
            await reticulum?.transport.stopWatchdog()
        }
    }

    /// Handle app returning to foreground. From runcore research:
    /// iOS leaves TCP sockets half-dead after suspend. Force-reconnect
    /// ALL TCP interfaces regardless of their apparent state. Wait 400ms
    /// after teardown before re-establishing (iOS needs time to release sockets).
    private func handleAppWillEnterForeground() async {
        guard let rns = reticulum else { return }

        networkStatus = .connecting

        // Force-reconnect all TCP interfaces (runcore lesson: always kick on resume)
        await rns.transport.forceReconnectAll()

        // Restart the watchdog
        await rns.transport.startWatchdog()

        // Brief delay for interfaces to stabilize (runcore uses up to 6s for TCP)
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Refresh status
        await refreshNetworkStatus()

        // Re-announce if auto-announce is enabled (from runcore: announce
        // after interfaces come online, not immediately on resume)
        if autoAnnounceEnabled {
            let name = storageService?.loadDisplayName()
            let loc = telemetryService?.currentLocation
            try? await messengerService?.announce(displayName: name, latitude: loc?.latitude, longitude: loc?.longitude)
        }
    }

    private func handleAppDidBecomeActive() async {
        isInForeground = true
        // Trigger an immediate refresh
        await refreshNetworkStatus()
    }

    // MARK: - Network Path Monitor

    /// Start monitoring network path changes. Uses NWPathMonitor to detect
    /// WiFi ↔ cellular transitions, VPN changes, etc. and trigger interface
    /// reconnection. From Columba-iOS research.
    private func startPathMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        self.pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self, self.isInitialized else { return }
                await self.handlePathChange(path)
            }
        }
        monitor.start(queue: pathMonitorQueue)
    }

    /// Handle a network path change. When the network path changes (e.g.,
    /// WiFi drops and cellular kicks in), force-reconnect interfaces.
    private func handlePathChange(_ path: NWPath) async {
        switch path.status {
        case .satisfied:
            // Network available — reconnect if we were disconnected
            if networkStatus != .connected {
                networkStatus = .connecting
                await reticulum?.transport.forceReconnectAll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await refreshNetworkStatus()
            }
        case .unsatisfied:
            networkStatus = .disconnected
        case .requiresConnection:
            networkStatus = .connecting
        @unknown default:
            break
        }
    }

    private func purgeExpiredMessages() {
        var changed = false
        for i in conversations.indices {
            let before = conversations[i].messages.count
            conversations[i].messages.removeAll { $0.isExpired }
            if conversations[i].messages.count != before {
                changed = true
            }
        }
        if changed {
            storageService?.saveConversations(conversations)
        }
    }

    private func defaultInterfaces() -> [RNSInterfaceConfig] {
        // Default: no interfaces configured, user must add one
        []
    }

    private func saveCurrentInterfaces() {
        storageService?.saveInterfaceConfigs(savedInterfaceConfigs)
    }

    // MARK: - User Preferences

    private func loadUserPreferences() {
        let defaults = UserDefaults.standard

        // One-time migration: enable mesh features for existing installs
        if !defaults.bool(forKey: "meshDefaultsV2Applied") {
            defaults.set(true, forKey: "autoAnnounce")
            defaults.set(true, forKey: "locationSharing")
            defaults.set(false, forKey: "transportMode")
            defaults.set(true, forKey: "meshDefaultsV2Applied")
        }

        // Rust engine is now mandatory — the pure-Swift LXMF stack can't
        // deliver. Force the flag on every launch so toggling it off via
        // older builds' UI doesn't strand the user without a working send
        // path.
        defaults.set(true, forKey: "rustEngineEnabled")

        // Register defaults for fresh installs
        defaults.register(defaults: [
            "autoAnnounce": true,
            "locationSharing": true,
            "transportMode": false,
            "propagationNode": false,
            "autoPublishDiagnostics": false,
            "streamDiagnostics": false,
            "rustEngineEnabled": true
        ])

        autoAnnounceEnabled = defaults.bool(forKey: "autoAnnounce")
        transportModeEnabled = defaults.bool(forKey: "transportMode")
        propagationNodeEnabled = defaults.bool(forKey: "propagationNode")
        locationSharingEnabled = defaults.bool(forKey: "locationSharing")
        autoPublishDiagnosticsEnabled = defaults.bool(forKey: "autoPublishDiagnostics")
        streamDiagnosticsEnabled = defaults.bool(forKey: "streamDiagnostics")
        ntfyTopic = defaults.string(forKey: "ntfyTopic") ?? ""
        rustEngineEnabled = defaults.bool(forKey: "rustEngineEnabled")
        lastDiagnosticsURL = defaults.string(forKey: "lastDiagnosticsURL")
        if let ts = defaults.object(forKey: "lastDiagnosticsAt") as? Date {
            lastDiagnosticsAt = ts
        }
    }

    private func saveUserPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(autoAnnounceEnabled, forKey: "autoAnnounce")
        defaults.set(transportModeEnabled, forKey: "transportMode")
        defaults.set(propagationNodeEnabled, forKey: "propagationNode")
        defaults.set(locationSharingEnabled, forKey: "locationSharing")
        defaults.set(autoPublishDiagnosticsEnabled, forKey: "autoPublishDiagnostics")
        defaults.set(streamDiagnosticsEnabled, forKey: "streamDiagnostics")
        defaults.set(ntfyTopic, forKey: "ntfyTopic")
        if let url = lastDiagnosticsURL { defaults.set(url, forKey: "lastDiagnosticsURL") }
        if let ts = lastDiagnosticsAt { defaults.set(ts, forKey: "lastDiagnosticsAt") }
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
