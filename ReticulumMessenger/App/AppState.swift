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

    // Settings
    @Published var autoAnnounceEnabled = false
    @Published var transportModeEnabled = false
    @Published var propagationNodeEnabled = false
    @Published var locationSharingEnabled = false

    // MARK: - Services

    private(set) var messengerService: MessengerService?
    private(set) var storageService: StorageService?
    private(set) var telemetryService: TelemetryService?

    // MARK: - Protocol Layer

    private var reticulum: Reticulum?
    private var lxmRouter: LXMRouter?
    private var rnodeInterface: RNodeInterface?
    private var autoAnnounceTimer: Timer?
    private var periodicUpdateTask: Task<Void, Never>?
    private var rnodeScanTask: Task<Void, Never>?
    private var discoveredRNodeIds: Set<UUID> = []
    private var savedInterfaceConfigs: [RNSInterfaceConfig] = []
    private var telemetryCancellable: AnyCancellable?

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
            .receive(on: RunLoop.main)
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

        // Haptic feedback
        NotificationService.shared.playMessageSentHaptic()

        // Send via LXMF router
        _ = try await router.send(message)
    }

    func sendAttachment(data: Data, mimeType: String, filename: String?, to destinationHash: Data) async throws {
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

        // Parse display name and optional location from appData.
        // Format: "displayName" or "displayName\x1Elat,lon"
        var displayName = name
        if let raw = appData {
            if let sep = raw.firstIndex(of: "\u{1E}") {
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

        let type: AnnounceEntry.AnnounceType
        if appData?.contains("lxmf") == true {
            type = .lxmf
        } else if appData?.contains("transport") == true {
            type = .transport
        } else if appData?.contains("node") == true {
            type = .node
        } else {
            type = .unknown
        }

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
    }

    private func startPeriodicUpdates() {
        periodicUpdateTask?.cancel()
        periodicUpdateTask = Task {
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
        autoAnnounceEnabled = defaults.bool(forKey: "autoAnnounce")
        transportModeEnabled = defaults.bool(forKey: "transportMode")
        propagationNodeEnabled = defaults.bool(forKey: "propagationNode")
        locationSharingEnabled = defaults.bool(forKey: "locationSharing")
    }

    private func saveUserPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(autoAnnounceEnabled, forKey: "autoAnnounce")
        defaults.set(transportModeEnabled, forKey: "transportMode")
        defaults.set(propagationNodeEnabled, forKey: "propagationNode")
        defaults.set(locationSharingEnabled, forKey: "locationSharing")
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
