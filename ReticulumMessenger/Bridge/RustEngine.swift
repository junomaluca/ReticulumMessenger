// SPDX-License-Identifier: MIT
// ReticulumMessenger — RustEngine.swift
//
// Thin Swift wrapper around the bundled Rusticulum + LXMF-rust FFI
// (RetichatFFI.xcframework). Brought in as the planned replacement for
// the pure-Swift ReticulumKit/LXMFKit stack — only the bits needed to
// initialise, expose the LXMF address, and observe inbound deliveries
// are wired up so far.
//
// Migration philosophy: stand the Rust engine up alongside the existing
// Swift stack (parallel, not in-place) so we can prove end-to-end with
// the echo bot before we cut the rest of MessengerService over to it.

import Foundation

/// Errors thrown by the Rust engine boundary.
enum RustEngineError: Error, LocalizedError {
    case startFailed(String)
    case sendFailed(String)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .startFailed(let m): return "Rust engine start failed: \(m)"
        case .sendFailed(let m): return "Rust engine send failed: \(m)"
        case .invalidArgument(let m): return "Rust engine bad arg: \(m)"
        }
    }
}

/// Wraps a single `lxmf_client_*` handle for the lifetime of the app.
/// Thread-safety follows the FFI's contract (callbacks dispatch onto the
/// supplied context; we marshal back to MainActor where needed).
final class RustEngine: @unchecked Sendable {

    /// Opaque handle returned by `lxmf_client_start`. Zero == uninitialised.
    private var handle: UInt64 = 0

    /// Storage location on disk. Co-located with the Documents dir so the
    /// keys persist across app re-installs (UserDefaults / app sandbox).
    private let baseDir: URL

    /// Cached delivery callback target.
    private var onDelivery: ((InboundMessage) -> Void)?
    private var onAnnounce: ((Data, String?) -> Void)?

    /// Snapshot of the local LXMF delivery destination hash (16 bytes).
    private(set) var lxmfHash: Data?

    /// Snapshot of the underlying identity hash (16 bytes).
    private(set) var identityHash: Data?

    struct InboundMessage {
        let messageHash: Data
        let sourceHash: Data
        let destinationHash: Data
        let title: String
        let content: String
        let timestamp: Date
        let signatureValid: Bool
        let fieldsRaw: Data
    }

    init() {
        let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        self.baseDir = docs?.appendingPathComponent("rust-engine", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory() + "rust-engine")
        try? FileManager.default.createDirectory(
            at: baseDir, withIntermediateDirectories: true
        )
    }

    /// Start the Rust LXMF client. Creates an identity on disk on first run.
    /// `displayName` is broadcast in announce app_data (LXMF v0.5.0+ format).
    func start(displayName: String) throws {
        guard handle == 0 else { return }

        let configDir = baseDir.appendingPathComponent("reticulum", isDirectory: true)
        let storage   = baseDir.appendingPathComponent("storage",   isDirectory: true)
        let identity  = baseDir.appendingPathComponent("identity")

        NSLog("[RustEngine] start: configDir=\(configDir.path)")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: storage,   withIntermediateDirectories: true)

        // Make sure the config has the testnet TCP hub — write a fresh one
        // if missing, otherwise heal an existing config that doesn't have it
        // (e.g. older installs that ran before this seed code was added).
        let configURL = configDir.appendingPathComponent("config")
        Self.ensureTestnetHubInConfig(at: configURL)
        if let body = try? String(contentsOf: configURL, encoding: .utf8) {
            NSLog("[RustEngine] config body bytes=\(body.count), has-michmesh=\(body.contains("rns.michmesh.net"))")
        } else {
            NSLog("[RustEngine] config NOT readable after seed at \(configURL.path)")
        }

        let createIdentity: Int32 = FileManager.default.fileExists(atPath: identity.path) ? 0 : 1

        let h = configDir.path.withCString { cfgPtr in
            storage.path.withCString { storPtr in
                identity.path.withCString { idPtr in
                    displayName.withCString { dnPtr in
                        lxmf_client_start(
                            cfgPtr, storPtr, idPtr,
                            createIdentity, dnPtr,
                            2,      // log_level: 2 = INFO
                            0       // stamp_cost: 0 = disabled
                        )
                    }
                }
            }
        }
        guard h != 0 else {
            let err = Self.lastError() ?? "unknown"
            NSLog("[RustEngine] lxmf_client_start FAILED: \(err)")
            throw RustEngineError.startFailed(err)
        }
        handle = h
        NSLog("[RustEngine] lxmf_client_start succeeded, handle=\(h)")

        // Cache our addresses.
        var idBuf = [UInt8](repeating: 0, count: 16)
        if lxmf_client_identity_hash(handle, &idBuf, 16) > 0 {
            identityHash = Data(idBuf)
        }
        var destBuf = [UInt8](repeating: 0, count: 16)
        if lxmf_client_dest_hash(handle, &destBuf, 16) > 0 {
            lxmfHash = Data(destBuf)
        }
        let idHex = identityHash?.map { String(format: "%02x", $0) }.joined() ?? "?"
        let lxHex = lxmfHash?.map { String(format: "%02x", $0) }.joined() ?? "?"
        NSLog("[RustEngine] identity=\(idHex) lxmf=\(lxHex)")

        // Wire the delivery callback.
        // The C callback's `context` pointer is an Unmanaged ref to `self`
        // so we can re-enter our Swift instance.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        _ = lxmf_client_set_delivery_callback(handle, { ctxPtr, hashPtr, hashLen, srcPtr, srcLen, dstPtr, dstLen, titlePtr, contentPtr, ts, sigValid, fieldsPtr, fieldsLen in
            guard let ctxPtr = ctxPtr else { return }
            let me = Unmanaged<RustEngine>.fromOpaque(ctxPtr).takeUnretainedValue()

            let msgHash = Data(bytes: hashPtr!, count: Int(hashLen))
            let src     = Data(bytes: srcPtr!,  count: Int(srcLen))
            let dst     = Data(bytes: dstPtr!,  count: Int(dstLen))
            let title   = titlePtr.flatMap { String(cString: $0) } ?? ""
            let content = contentPtr.flatMap { String(cString: $0) } ?? ""
            let fields: Data = {
                guard fieldsLen > 0, let p = fieldsPtr else { return Data() }
                return Data(bytes: p, count: Int(fieldsLen))
            }()

            let inbound = InboundMessage(
                messageHash: msgHash,
                sourceHash: src,
                destinationHash: dst,
                title: title,
                content: content,
                timestamp: Date(timeIntervalSince1970: ts),
                signatureValid: sigValid != 0,
                fieldsRaw: fields
            )
            let fromHex = src.map { String(format: "%02x", $0) }.joined()
            NSLog("[RustEngine] DELIVERED from=\(fromHex) sig=\(sigValid != 0) bytes=\(content.utf8.count) title='\(title)'")
            me.onDelivery?(inbound)
        }, ctx)

        // Wire announce callback.
        _ = lxmf_client_set_announce_callback(handle, { ctxPtr, destPtr, destLen, namePtr in
            guard let ctxPtr = ctxPtr else { return }
            let me = Unmanaged<RustEngine>.fromOpaque(ctxPtr).takeUnretainedValue()
            let dest = Data(bytes: destPtr!, count: Int(destLen))
            let name = namePtr.flatMap { String(cString: $0) }
            me.onAnnounce?(dest, name)
        }, ctx)
    }

    /// Register a closure for inbound LXMF messages. Replaces any previous handler.
    func setDeliveryHandler(_ handler: @escaping (InboundMessage) -> Void) {
        onDelivery = handler
    }

    /// Register a closure for inbound LXMF announces.
    func setAnnounceHandler(_ handler: @escaping (Data, String?) -> Void) {
        onAnnounce = handler
    }

    /// Announce our delivery destination to the network.
    @discardableResult
    func announce() -> Bool {
        guard handle != 0 else { return false }
        let rc = lxmf_client_announce(handle)
        NSLog("[RustEngine] announce rc=\(rc)")
        return rc == 0
    }

    /// Register the delivery destination for automatic re-announce.
    /// The Rust transport will then re-announce on every interface
    /// false→true transition (so newly-connected TCP hubs see us) and
    /// every `refreshSeconds` thereafter (0 to disable periodic refresh).
    /// Idempotent: a second call updates the entry.
    @discardableResult
    func publish(refreshSeconds: Double = 600) -> Bool {
        guard handle != 0 else { return false }
        let rc = lxmf_client_publish(handle, refreshSeconds)
        NSLog("[RustEngine] publish refresh=\(refreshSeconds) rc=\(rc)")
        return rc == 0
    }

    /// Query whether the named interface is currently online (1) / offline (0)
    /// / unknown (-1). Useful for confirming the TCP hub actually connected.
    func interfaceOnline(_ name: String) -> Int32 {
        return name.withCString { rns_interface_online($0) }
    }

    /// Send a small text message via the Rust LXMF stack. Returns the message hash on success.
    @discardableResult
    func sendText(to destHash: Data, content: String, title: String = "") throws -> Data {
        guard handle != 0 else { throw RustEngineError.sendFailed("engine not started") }
        guard destHash.count == 16 else { throw RustEngineError.invalidArgument("destHash must be 16 bytes") }

        let msg = destHash.withUnsafeBytes { destBytes -> UInt64 in
            content.withCString { cPtr in
                title.withCString { tPtr in
                    lxmf_message_new(
                        handle,
                        destBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        UInt32(destHash.count),
                        cPtr, tPtr,
                        2  // method: 2 = DIRECT (Rust impl auto-selects single packet vs resource)
                    )
                }
            }
        }
        guard msg != 0 else { throw RustEngineError.sendFailed(Self.lastError() ?? "lxmf_message_new returned 0") }
        defer { _ = lxmf_message_destroy(msg) }

        let rc = lxmf_message_send(handle, msg)
        guard rc == 0 else { throw RustEngineError.sendFailed(Self.lastError() ?? "lxmf_message_send rc=\(rc)") }

        var hashBuf = [UInt8](repeating: 0, count: 32)
        let n = lxmf_message_hash(msg, &hashBuf, 32)
        return n > 0 ? Data(hashBuf.prefix(Int(n))) : Data()
    }

    /// Send an arbitrary binary attachment alongside an optional text body.
    /// Uses the official LXMF FIELD_FILE_ATTACHMENTS / IMAGE / AUDIO routing.
    @discardableResult
    func sendAttachment(to destHash: Data, data: Data, mimeType: String, filename: String,
                        title: String = "", body: String = "") throws -> Data {
        guard handle != 0 else { throw RustEngineError.sendFailed("engine not started") }
        guard destHash.count == 16 else { throw RustEngineError.invalidArgument("destHash must be 16 bytes") }

        let msg = destHash.withUnsafeBytes { destBytes -> UInt64 in
            body.withCString { cPtr in
                title.withCString { tPtr in
                    lxmf_message_new(
                        handle,
                        destBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        UInt32(destHash.count),
                        cPtr, tPtr,
                        2  // DIRECT
                    )
                }
            }
        }
        guard msg != 0 else { throw RustEngineError.sendFailed(Self.lastError() ?? "lxmf_message_new returned 0") }
        defer { _ = lxmf_message_destroy(msg) }

        _ = filename.withCString { fnamePtr in
            data.withUnsafeBytes { dataBytes -> Int32 in
                lxmf_message_add_attachment(
                    msg, fnamePtr,
                    dataBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    UInt32(data.count)
                )
            }
        }
        _ = lxmf_message_add_field(msg, 0xF0, mimeType)  // custom MIME tag

        let rc = lxmf_message_send(handle, msg)
        guard rc == 0 else { throw RustEngineError.sendFailed(Self.lastError() ?? "lxmf_message_send rc=\(rc)") }

        var hashBuf = [UInt8](repeating: 0, count: 32)
        let n = lxmf_message_hash(msg, &hashBuf, 32)
        return n > 0 ? Data(hashBuf.prefix(Int(n))) : Data()
    }

    // MARK: - Helpers

    /// Ensure the Reticulum config at `url` has the MichMesh testnet TCP hub
    /// interface defined. Three cases:
    ///   1. File doesn't exist → write a minimal config including the hub.
    ///   2. File exists but doesn't reference rns.michmesh.net → append the
    ///      hub stanza so the engine has a working WAN path.
    ///   3. File exists and already has the hub → no-op.
    /// Heals installs that ran before the original seed code shipped.
    private static func ensureTestnetHubInConfig(at url: URL) {
        let hubStanza = """

          [[Community Hub Testnet]]
            type = TCPClientInterface
            enabled = yes
            target_host = rns.michmesh.net
            target_port = 7822
        """

        if !FileManager.default.fileExists(atPath: url.path) {
            let body = """
            # Seeded by ReticulumMessenger on first run.
            # Edit freely — this file is left alone on subsequent launches,
            # except that the MichMesh testnet hub stanza is auto-appended
            # if it ever goes missing.

            [reticulum]
            enable_transport = False
            share_instance = Yes
            instance_name = default

            [logging]
            loglevel = 4

            [interfaces]

              [[Default Interface]]
                type = AutoInterface
                enabled = Yes
            \(hubStanza)
            """
            try? body.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        if let body = try? String(contentsOf: url, encoding: .utf8),
           !body.contains("rns.michmesh.net") {
            let appended = body + "\n" + hubStanza + "\n"
            try? appended.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func lastError() -> String? {
        guard let cStr = lxmf_last_error() else { return nil }
        defer { lxmf_free_string(cStr) }
        return String(cString: cStr)
    }
}
