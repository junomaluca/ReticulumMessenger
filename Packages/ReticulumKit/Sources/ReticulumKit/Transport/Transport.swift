// SPDX-License-Identifier: MIT
// ReticulumKit — Transport.swift
// Path management and packet routing for the Reticulum network.

import Foundation

/// Manages path discovery, caching, and packet routing across interfaces.
/// The transport layer is responsible for getting packets from source to destination
/// across potentially multiple hops and interfaces.
public actor RNSTransport {

    // MARK: - Types

    /// A cached path to a destination.
    public struct PathEntry: Sendable {
        public let destinationHash: Data
        public let nextHop: Data?
        public let interfaceName: String
        public let hops: UInt8
        public let expires: Date
        public let announceData: Data?

        public var isExpired: Bool {
            Date() > expires
        }
    }

    /// An announce handler registration.
    struct AnnounceHandler {
        let appName: String
        let callback: @Sendable (Data, RNSIdentity, Data?) -> Void
    }

    // MARK: - Properties

    /// Registered network interfaces.
    private var interfaces: [String: any RNSInterface] = [:]

    /// Path table: destination hash -> path entry.
    private var pathTable: [Data: PathEntry] = [:]

    /// Registered destinations (local endpoints).
    private var destinations: [Data: RNSDestination] = [:]

    /// Registered announce handlers.
    private var announceHandlers: [AnnounceHandler] = []

    /// Packet deduplication cache.
    private var recentPacketHashes: Set<Data> = []
    private var packetHashTimestamps: [(hash: Data, time: Date)] = []

    /// Packet processing statistics for diagnostics.
    public private(set) var packetsReceived: UInt64 = 0
    public private(set) var packetsParseFailed: UInt64 = 0
    public private(set) var packetsDeduplicated: UInt64 = 0
    public private(set) var announcesProcessed: UInt64 = 0
    public private(set) var pathRequestsReceived: UInt64 = 0
    public private(set) var pathResponsesSent: UInt64 = 0
    public private(set) var announcesSent: UInt64 = 0
    public private(set) var dataPacketsForLocal: UInt64 = 0
    public private(set) var dataPacketsUnmatched: UInt64 = 0
    public private(set) var packetsSent: UInt64 = 0
    public private(set) var pathRequestsSent: UInt64 = 0
    public private(set) var sendErrors: UInt64 = 0
    public private(set) var lastSendError: String?

    /// Pending path requests.
    private var pendingPathRequests: [Data: Date] = [:]

    /// Packet receipts awaiting proof.
    private var pendingReceipts: [Data: RNSPacketReceipt] = [:]

    /// Active links.
    private var activeLinks: [Data: RNSLink] = [:]

    /// Maximum age for deduplication cache entries.
    private let deduplicationWindow: TimeInterval = 60.0

    /// Maximum age for path entries.
    private let pathTimeout: TimeInterval = 3600.0

    /// Interface watchdog task — monitors health of all interfaces.
    private var watchdogTask: Task<Void, Never>?

    /// How often the watchdog checks interface health (seconds).
    private let watchdogInterval: TimeInterval = 5.0


    /// Path response continuations waiting for paths, keyed by destination hash then waiter UUID.
    private var pathResponseWaiters: [Data: [UUID: CheckedContinuation<Bool, Never>]] = [:]

    /// Destination hash for the well-known path request destination.
    /// Python RNS computes a PLAIN destination hash as:
    ///   name_hash = SHA256(full_name)[:nameHashLength]   // 10 bytes
    ///   hash      = SHA256(name_hash)[:truncatedHashLength]  // 16 bytes
    /// Computing SHA256(name)[:16] directly is wrong and yields a hash no other
    /// RNS node will recognize, causing path requests to be silently dropped
    /// on both inbound and outbound paths.
    private static let pathRequestDestinationHash: Data = {
        let name = "rnstransport.path.request"
        let nameHash = Data(RNSCrypto.sha256(Data(name.utf8)).prefix(RNS.nameHashLength))
        return Data(RNSCrypto.sha256(nameHash).prefix(RNS.truncatedHashLength))
    }()

    // MARK: - Initialization

    public init() {}

    // MARK: - Interface Management

    /// Whether transport mode is enabled (relay packets for other nodes).
    private var transportEnabled = false

    /// Simple announce callbacks: (hash, displayName, appData).
    private var simpleAnnounceCallbacks: [@Sendable (Data, String?, String?) -> Void] = []

    /// Local identity hash (set by Reticulum on start). Used in path requests
    /// to match the Python reference format: data = destHash + requestorHash.
    private var localIdentityHash: Data?

    /// Set the local identity hash for path request data.
    public func setLocalIdentityHash(_ hash: Data) {
        localIdentityHash = hash
    }

    /// Register a network interface.
    public func addInterface(_ interface: any RNSInterface) {
        interfaces[interface.name] = interface
    }

    /// Register a network interface (alias).
    public func registerInterface(_ interface: any RNSInterface) {
        addInterface(interface)
    }

    /// Whether at least one interface is currently online.
    public var hasOnlineInterface: Bool {
        interfaces.values.contains { $0.isOnline }
    }

    /// Wait until at least one interface is online (with timeout).
    /// Returns true if an interface came online, false on timeout.
    public func waitForOnlineInterface(timeout: TimeInterval = 10.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasOnlineInterface { return true }
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
        }
        return hasOnlineInterface
    }

    /// Remove a network interface.
    public func removeInterface(name: String) {
        interfaces.removeValue(forKey: name)
    }

    /// Get all registered interfaces.
    public func getInterfaces() -> [any RNSInterface] {
        Array(interfaces.values)
    }

    // MARK: - Destination Registration

    /// Register a local destination to receive packets.
    public func registerDestination(_ destination: RNSDestination) {
        destinations[destination.hash] = destination
    }

    /// Unregister a local destination.
    public func deregisterDestination(_ destination: RNSDestination) {
        destinations.removeValue(forKey: destination.hash)
    }

    /// Get all registered local destinations.
    public func allDestinations() -> [RNSDestination] {
        Array(destinations.values)
    }

    // MARK: - Announce Handling

    /// Register a handler for announce packets.
    public func registerAnnounceHandler(
        appName: String,
        callback: @escaping @Sendable (Data, RNSIdentity, Data?) -> Void
    ) {
        announceHandlers.append(AnnounceHandler(appName: appName, callback: callback))
    }

    /// Register a simplified announce handler (hash, displayName, appData).
    public func onAnnounce(_ callback: @escaping @Sendable (Data, String?, String?) -> Void) {
        simpleAnnounceCallbacks.append(callback)
    }

    /// Enable or disable transport mode (relay packets for other nodes).
    public func setTransportEnabled(_ enabled: Bool) {
        transportEnabled = enabled
    }

    // MARK: - Path Management

    /// Look up a path to a destination.
    public func findPath(to destinationHash: Data) -> PathEntry? {
        guard let entry = pathTable[destinationHash], !entry.isExpired else {
            return nil
        }
        return entry
    }

    /// Check if a path to a destination is known.
    public func hasPath(to destinationHash: Data) -> Bool {
        findPath(to: destinationHash) != nil
    }

    /// Request a path to a destination from the network.
    /// Sends a broadcast path request matching the Python reference protocol:
    /// destination = well-known "rnstransport.path.request" PLAIN hash,
    /// context = .pathResponse, data = the destination hash being sought.
    public func requestPath(to destinationHash: Data) async throws {
        // Check if we already have a pending request
        if let lastRequest = pendingPathRequests[destinationHash],
           Date().timeIntervalSince(lastRequest) < RNS.pathRequestBlacklist {
            return
        }

        pendingPathRequests[destinationHash] = Date()
        pathRequestsSent += 1

        // Python reference path request format:
        //   destination = well-known "rnstransport.path.request" PLAIN hash
        //   data = destinationHash(16) + requestorIdentityHash(16)
        //   context = NONE (Python identifies path requests by destination hash, not context)
        var requestData = Data()
        requestData.append(destinationHash)
        if let idHash = localIdentityHash {
            requestData.append(idHash)
        }

        let packet = RNSPacket(
            propagationType: .broadcast,
            destinationType: .plain,
            packetType: .data,
            destinationHash: Self.pathRequestDestinationHash,
            context: .none,
            data: requestData
        )

        try await broadcastPacket(packet)
    }

    /// Register a discovered path.
    public func registerPath(
        destinationHash: Data,
        nextHop: Data?,
        interfaceName: String,
        hops: UInt8,
        announceData: Data? = nil
    ) {
        let entry = PathEntry(
            destinationHash: destinationHash,
            nextHop: nextHop,
            interfaceName: interfaceName,
            hops: hops,
            expires: Date().addingTimeInterval(pathTimeout),
            announceData: announceData
        )

        // Only update if this path is shorter or the existing one has expired
        if let existing = pathTable[destinationHash], !existing.isExpired {
            if hops < existing.hops {
                pathTable[destinationHash] = entry
            }
        } else {
            pathTable[destinationHash] = entry
        }

        // Notify anyone waiting for a path to this destination
        notifyPathWaiters(for: destinationHash)
    }

    /// Get all known paths.
    public func allPaths() -> [PathEntry] {
        Array(pathTable.values.filter { !$0.isExpired })
    }

    // MARK: - Packet Sending

    /// Send a packet to a destination.
    public func sendPacket(_ packet: RNSPacket) async throws -> RNSPacketReceipt? {
        let raw = packet.pack()

        do {
            // Try to find a specific path
            if let path = findPath(to: packet.destinationHash),
               let interface = interfaces[path.interfaceName] {
                if raw.count > RNS.mtu && !interface.isStreamInterface {
                    throw RNSPacketError.payloadTooLarge
                }
                try await interface.send(raw)
            } else {
                guard raw.count <= RNS.mtu else {
                    throw RNSPacketError.payloadTooLarge
                }
                try await broadcastPacket(packet)
            }
            packetsSent += 1
        } catch {
            sendErrors += 1
            lastSendError = "\(error.localizedDescription) (dest:\(packet.destinationHash.prefix(4).map { String(format: "%02x", $0) }.joined()) type:\(packet.packetType))"
            throw error
        }

        if packet.packetType == .announce {
            announcesSent += 1
        }

        // Create receipt for data packets
        if packet.packetType == .data {
            let receipt = RNSPacketReceipt(
                packetHash: packet.packetHash,
                destinationHash: packet.destinationHash
            )
            pendingReceipts[packet.packetHash] = receipt
            return receipt
        }

        return nil
    }

    /// Broadcast a packet on all online interfaces.
    private func broadcastPacket(_ packet: RNSPacket) async throws {
        let raw = packet.pack()
        for (_, interface) in interfaces where interface.isOnline {
            try? await interface.send(raw)
        }
    }

    // MARK: - Packet Processing

    /// Process an incoming packet from an interface.
    public func processIncoming(data: Data, from interfaceName: String) {
        packetsReceived += 1

        guard let packet = try? RNSPacket.unpack(data) else {
            packetsParseFailed += 1
            return
        }

        // Deduplication
        let hash = packet.packetHash
        if recentPacketHashes.contains(hash) {
            packetsDeduplicated += 1
            return
        }
        recentPacketHashes.insert(hash)
        packetHashTimestamps.append((hash: hash, time: Date()))
        cleanDeduplicationCache()

        switch packet.packetType {
        case .data:
            handleDataPacket(packet, from: interfaceName)
        case .announce:
            handleAnnouncePacket(packet, from: interfaceName)
        case .linkRequest:
            handleLinkRequest(packet, from: interfaceName)
        case .proof:
            handleProof(packet)
        }
    }

    // MARK: - Packet Handlers

    private func handleDataPacket(_ packet: RNSPacket, from interfaceName: String) {
        // Path REQUEST detection: Python Reticulum identifies path requests purely
        // by destination hash matching the well-known path request destination,
        // regardless of context byte (may be NONE, PATH_RESPONSE, etc.).
        if packet.destinationHash == Self.pathRequestDestinationHash &&
           packet.data.count >= RNS.truncatedHashLength {
            handlePathRequest(packet, from: interfaceName)
            return
        }

        // Path RESPONSE detection: context == PATH_RESPONSE (0x0B) and
        // destination hash is the actual destination being sought.
        if packet.context == .pathResponse && packet.data.count >= RNS.truncatedHashLength {
            let respondedHash = Data(packet.data.prefix(RNS.truncatedHashLength))
            registerPath(
                destinationHash: respondedHash,
                nextHop: nil,
                interfaceName: interfaceName,
                hops: packet.hops
            )
            return
        }

        // Check if this is for a local destination
        if let destination = destinations[packet.destinationHash] {
            dataPacketsForLocal += 1
            destination.packetCallback?(packet)
        } else if activeLinks[packet.destinationHash] == nil {
            dataPacketsUnmatched += 1
        }

        // Check if this is for an active link
        if let link = activeLinks[packet.destinationHash] {
            link.receivePacket(packet)
        }
    }

    /// Handle an incoming path request from another node.
    /// If we host the requested destination, respond with an announce
    /// (matching the Python reference behavior). If transport mode is
    /// enabled and we have a cached path, forward a path response.
    private func handlePathRequest(_ packet: RNSPacket, from interfaceName: String) {
        pathRequestsReceived += 1
        let requestedHash = Data(packet.data.prefix(RNS.truncatedHashLength))

        // Check if we host this destination locally
        if let destination = destinations[requestedHash] {
            // Respond with an announce for this destination — this is what the
            // Python reference implementation does. The announce carries the full
            // identity (public keys) needed for encryption and establishes the path.
            if let announceData = try? destination.announce() {
                let announcePacket = RNSPacket.announce(from: destination, data: announceData)
                pathResponsesSent += 1
                Task { [weak self] in
                    _ = try? await self?.sendPacket(announcePacket)
                }
            }
            return
        }

        // If transport mode is enabled, check our path table for a cached path
        // and forward a path response on behalf of the destination.
        if transportEnabled, findPath(to: requestedHash) != nil {
            let response = RNSPacket(
                propagationType: .broadcast,
                destinationType: .plain,
                packetType: .data,
                destinationHash: requestedHash,
                context: .pathResponse,
                data: requestedHash
            )
            Task { [weak self] in
                try? await self?.broadcastPacket(response)
            }
        }
    }

    private func handleAnnouncePacket(_ packet: RNSPacket, from interfaceName: String) {
        announcesProcessed += 1

        // Parse announce data to extract identity
        let data = packet.data
        let signatureSize = 64
        // Minimum announce: pubkey(64) + nameHash(10) + randomHash(10) + sig(64) = 148
        guard data.count >= RNS.identityKeySize + 10 + 10 + signatureSize else { return }

        let pubKeyBytes = data.prefix(RNS.identityKeySize)
        guard let identity = try? RNSIdentity(publicKeyBytes: Data(pubKeyBytes)) else { return }

        // Register path from this announce
        registerPath(
            destinationHash: packet.destinationHash,
            nextHop: nil,
            interfaceName: interfaceName,
            hops: packet.hops,
            announceData: packet.data
        )

        // Announce body layouts:
        //   Python (new):  pubkey(64) | nameHash(10) | randomHash(10) | [ratchet(32)] | signature(64) | appData(?)
        //   Old Swift:     pubkey(64) | nameHash(10) | randomHash(10) | appData(?) | signature(64)
        //
        // Detect format by trying signature verification in both positions.
        // If verification is inconclusive, fall back to trying both text extractions.
        let headerBase = RNS.identityKeySize + RNS.nameHashLength + RNS.randomHashLength  // 84
        let hasRatchet = packet.contextFlag && (data.count >= headerBase + 32 + signatureSize)
        let sigOffsetNew = hasRatchet ? headerBase + 32 : headerBase
        let appDataOffsetNew = sigOffsetNew + signatureSize

        var appData: Data?

        if data.count >= appDataOffsetNew {
            // Extract candidates from both formats
            let appDataNew: Data? = data.count > appDataOffsetNew ? Data(data[appDataOffsetNew...]) : nil
            let appDataOld: Data? = data.count > headerBase + signatureSize ?
                Data(data[headerBase..<(data.count - signatureSize)]) : nil

            // Try signature verification for new format
            let sigNew = Data(data[sigOffsetNew..<appDataOffsetNew])
            var signedDataNew = Data()
            signedDataNew.append(packet.destinationHash)
            signedDataNew.append(data.prefix(sigOffsetNew))
            if let ad = appDataNew { signedDataNew.append(ad) }

            if identity.verify(signature: sigNew, for: signedDataNew) {
                appData = appDataNew
            } else {
                // Try signature verification for old format
                let sigOld = Data(data[(data.count - signatureSize)...])
                var signedDataOld = Data()
                signedDataOld.append(packet.destinationHash)
                signedDataOld.append(data.prefix(headerBase))
                if let ad = appDataOld { signedDataOld.append(ad) }

                if identity.verify(signature: sigOld, for: signedDataOld) {
                    appData = appDataOld
                } else {
                    // Neither signature verified. Try heuristic: if old-format
                    // appData decodes as valid UTF-8, use it; otherwise use new.
                    if let oldData = appDataOld,
                       String(data: oldData, encoding: .utf8) != nil {
                        appData = appDataOld
                    } else {
                        appData = appDataNew
                    }
                }
            }
        }

        // Notify announce handlers
        for handler in announceHandlers {
            handler.callback(packet.destinationHash, identity, appData)
        }

        // Notify simple announce callbacks
        let displayName = appData.flatMap { String(data: $0, encoding: .utf8) }
        for callback in simpleAnnounceCallbacks {
            callback(packet.destinationHash, displayName, displayName)
        }
    }

    private func handleLinkRequest(_ packet: RNSPacket, from interfaceName: String) {
        if let destination = destinations[packet.destinationHash] {
            // Create a link for this request
            if let link = try? RNSLink(
                destination: destination,
                requestData: packet.data,
                interfaceName: interfaceName
            ) {
                activeLinks[link.linkHash] = link
                destination.linkCallback?(link)
            }
        }
    }

    private func handleProof(_ packet: RNSPacket) {
        // Find and resolve matching receipt
        if let receipt = pendingReceipts[packet.destinationHash] {
            receipt.prove()
            pendingReceipts.removeValue(forKey: packet.destinationHash)
        }
    }

    // MARK: - Link Management

    /// Register an active link.
    public func registerLink(_ link: RNSLink) {
        activeLinks[link.linkHash] = link
    }

    /// Remove a link.
    public func removeLink(_ link: RNSLink) {
        activeLinks.removeValue(forKey: link.linkHash)
    }

    // MARK: - Interface Health Watchdog

    /// Start the interface health watchdog. Periodically checks all interfaces
    /// and detects stale TCP connections (iOS suspend/resume leaves sockets half-dead).
    /// Learned from runcore: poll every few seconds and force-reconnect stale interfaces.
    public func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.watchdogInterval ?? 5.0) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.runWatchdogCheck()
            }
        }
    }

    /// Stop the interface health watchdog.
    public func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// Force-reconnect all TCP interfaces. Called on app resume because
    /// iOS leaves sockets half-dead after suspend. From runcore: always
    /// kick TCP connections on resume regardless of apparent state.
    public func forceReconnectAll() async {
        for (_, interface) in interfaces {
            if let tcp = interface as? TCPClientInterface {
                try? await tcp.forceReconnect()
            }
        }
    }

    /// Single watchdog iteration — check each interface for staleness.
    private func runWatchdogCheck() async {
        for (_, interface) in interfaces {
            if let tcp = interface as? TCPClientInterface, tcp.isStale {
                try? await tcp.forceReconnect()
            }
        }
    }

    // MARK: - Path Response Handling

    /// Wait for a path to become available (with timeout).
    /// Returns true if a path was found, false on timeout.
    public func waitForPath(to destinationHash: Data, timeout: TimeInterval = 10.0) async -> Bool {
        // Check if already known
        if hasPath(to: destinationHash) { return true }

        let waiterID = UUID()

        // Wait with timeout
        return await withCheckedContinuation { continuation in
            if pathResponseWaiters[destinationHash] == nil {
                pathResponseWaiters[destinationHash] = [:]
            }
            pathResponseWaiters[destinationHash]?[waiterID] = continuation

            // Timeout task — only cancels this specific waiter
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.cancelPathWaiter(for: destinationHash, waiterID: waiterID)
            }
        }
    }

    /// Cancel a single path waiter that timed out (by its UUID).
    private func cancelPathWaiter(for hash: Data, waiterID: UUID) {
        guard let continuation = pathResponseWaiters[hash]?.removeValue(forKey: waiterID) else {
            return // Already resumed by notifyPathWaiters
        }
        continuation.resume(returning: hasPath(to: hash))

        // Clean up empty dictionaries
        if pathResponseWaiters[hash]?.isEmpty == true {
            pathResponseWaiters.removeValue(forKey: hash)
        }
    }

    /// Notify path waiters when a new path is registered.
    private func notifyPathWaiters(for destinationHash: Data) {
        guard let waiters = pathResponseWaiters.removeValue(forKey: destinationHash) else { return }
        for (_, continuation) in waiters {
            continuation.resume(returning: true)
        }
    }

    // MARK: - Maintenance

    /// Remove expired entries from the deduplication cache.
    private func cleanDeduplicationCache() {
        let cutoff = Date().addingTimeInterval(-deduplicationWindow)
        while let first = packetHashTimestamps.first, first.time < cutoff {
            recentPacketHashes.remove(first.hash)
            packetHashTimestamps.removeFirst()
        }
    }

    /// Clean expired paths from the path table and stale pending requests.
    public func cleanExpiredPaths() {
        pathTable = pathTable.filter { !$0.value.isExpired }

        // Clean pending path requests older than the blacklist window
        let cutoff = Date().addingTimeInterval(-RNS.pathRequestBlacklist)
        pendingPathRequests = pendingPathRequests.filter { $0.value > cutoff }
    }

    // MARK: - Diagnostics

    /// Probe a destination to diagnose delivery issues. Returns a step-by-step report.
    public func probePath(to destinationHash: Data) async -> String {
        let hex = destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        var report = "PROBE \(hex)...\n"

        // Step 1: Check path table
        if let path = findPath(to: destinationHash) {
            report += "✓ Path found: via \(path.interfaceName), \(path.hops) hops, expires \(Int(path.expires.timeIntervalSinceNow))s\n"

            // Step 2: Check interface exists and is online
            if let iface = interfaces[path.interfaceName] {
                report += "✓ Interface '\(iface.name)' exists, online=\(iface.isOnline)\n"
                if !iface.isOnline {
                    report += "✗ PROBLEM: Interface is offline — packet can't be sent\n"
                }
            } else {
                report += "✗ PROBLEM: Interface '\(path.interfaceName)' not found in registered interfaces\n"
                let names = interfaces.keys.joined(separator: ", ")
                report += "  Available: [\(names)]\n"
            }
        } else {
            report += "✗ No path in table\n"

            // Step 2b: Try requesting a path
            report += "→ Sending path request...\n"
            do {
                try await requestPath(to: destinationHash)
                report += "✓ Path request sent, waiting 5s...\n"
                let found = await waitForPath(to: destinationHash, timeout: 5.0)
                if found {
                    if let path = findPath(to: destinationHash) {
                        report += "✓ Path discovered: via \(path.interfaceName), \(path.hops) hops\n"
                    }
                } else {
                    report += "✗ PROBLEM: No path response after 5s — peer may be unreachable\n"
                }
            } catch {
                report += "✗ Path request failed: \(error.localizedDescription)\n"
            }
        }

        // Step 3: Check registered destinations
        report += "Registered destinations: \(destinations.count)\n"
        for (hash, dest) in destinations {
            report += "  \(hash.prefix(4).map { String(format: "%02x", $0) }.joined())... (\(dest.appName))\n"
        }

        // Step 4: Interfaces summary
        report += "Interfaces: \(interfaces.count)\n"
        for (name, iface) in interfaces {
            report += "  \(name): online=\(iface.isOnline)\n"
        }

        return report
    }

    /// Get transport statistics.
    public func statistics() -> TransportStatistics {
        TransportStatistics(
            interfaceCount: interfaces.count,
            onlineInterfaces: interfaces.values.filter { $0.isOnline }.count,
            knownPaths: pathTable.count,
            activeLinks: activeLinks.count,
            pendingReceipts: pendingReceipts.count,
            registeredDestinations: destinations.count,
            packetsReceived: packetsReceived,
            packetsParseFailed: packetsParseFailed,
            packetsDeduplicated: packetsDeduplicated,
            announcesProcessed: announcesProcessed,
            announcesSent: announcesSent,
            pathRequestsReceived: pathRequestsReceived,
            pathResponsesSent: pathResponsesSent,
            dataPacketsForLocal: dataPacketsForLocal,
            dataPacketsUnmatched: dataPacketsUnmatched,
            packetsSent: packetsSent,
            pathRequestsSent: pathRequestsSent,
            sendErrors: sendErrors,
            lastSendError: lastSendError
        )
    }
}

// MARK: - Statistics

public struct TransportStatistics: Sendable {
    public let interfaceCount: Int
    public let onlineInterfaces: Int
    public let knownPaths: Int
    public let activeLinks: Int
    public let pendingReceipts: Int
    public let registeredDestinations: Int
    public let packetsReceived: UInt64
    public let packetsParseFailed: UInt64
    public let packetsDeduplicated: UInt64
    public let announcesProcessed: UInt64
    public let announcesSent: UInt64
    public let pathRequestsReceived: UInt64
    public let pathResponsesSent: UInt64
    public let dataPacketsForLocal: UInt64
    public let dataPacketsUnmatched: UInt64
    public let packetsSent: UInt64
    public let pathRequestsSent: UInt64
    public let sendErrors: UInt64
    public let lastSendError: String?
}
