// SPDX-License-Identifier: MIT
// ReticulumMessenger — DiagnosticsService.swift
// Builds a plain-text diagnostic snapshot and publishes it to a paste service.

import Foundation
import UIKit
import ReticulumKit

enum DiagnosticsService {

    enum PublishError: Error, LocalizedError {
        case http(Int)
        case empty
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .http(let code): return "Paste service returned HTTP \(code)"
            case .empty: return "Paste service returned an empty body"
            case .invalidResponse: return "Paste service returned an unexpected response"
            }
        }
    }

    /// Build a plain-text snapshot of everything useful for remote debugging.
    /// Identity / destination hashes are public network data; conversation content is excluded.
    @MainActor
    static func buildReport(appState: AppState) -> String {
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        var out = ""
        out += "=== ReticulumMessenger Diagnostics ===\n"
        out += "Generated: \(isoFormatter.string(from: Date()))\n"
        out += "App: \(appVersion) (\(buildNumber))\n"
        out += "Device: \(device.model) iOS \(device.systemVersion)\n"
        out += "\n"

        out += "=== Identity ===\n"
        out += "Identity Hash: \(appState.localIdentityHash.isEmpty ? "(none)" : appState.localIdentityHash)\n"
        out += "LXMF Address:  \(appState.deliveryHash.isEmpty ? "(none)" : appState.deliveryHash)\n"
        out += "\n"

        out += "=== Network ===\n"
        out += "Status: \(appState.networkStatus.label)\n"
        let online = appState.interfaces.filter(\.isOnline).count
        out += "Interfaces: \(appState.interfaces.count) (\(online) online)\n"
        for iface in appState.interfaces {
            let onlineFlag = iface.isOnline ? "ONLINE " : "OFFLINE"
            let tx = InterfaceInfo.formatBytes(iface.bytesSent)
            let rx = InterfaceInfo.formatBytes(iface.bytesReceived)
            out += "  [\(onlineFlag)] \(iface.name) — \(iface.type) — \(iface.statusText)\n"
            out += "             tx:\(tx)  rx:\(rx)\n"
        }
        out += "\n"

        out += "=== Packet Stats ===\n"
        out += appState.packetDiagnostics.isEmpty ? "(none — stack may not be running)\n" : (appState.packetDiagnostics + "\n")
        out += "\n"

        out += "=== Known Peers (\(appState.knownPeers.count)) ===\n"
        if appState.knownPeers.isEmpty {
            out += "(none)\n"
        } else {
            for peer in appState.knownPeers.prefix(50) {
                out += "  \(peer.hexHash) — \(peer.displayName) — \(isoFormatter.string(from: peer.lastSeen))\n"
            }
            if appState.knownPeers.count > 50 {
                out += "  …(+\(appState.knownPeers.count - 50) more)\n"
            }
        }
        out += "\n"

        out += "=== Recent Announces (\(appState.announceStream.count)) ===\n"
        if appState.announceStream.isEmpty {
            out += "(none yet)\n"
        } else {
            for ann in appState.announceStream.prefix(30) {
                let name = ann.displayName ?? "(no name)"
                out += "  \(isoFormatter.string(from: ann.timestamp))  \(ann.hash)  \(name)\n"
            }
            if appState.announceStream.count > 30 {
                out += "  …(+\(appState.announceStream.count - 30) more)\n"
            }
        }
        out += "\n"

        out += "=== Conversations ===\n"
        out += "Count: \(appState.conversations.count)\n"
        let totalMessages = appState.conversations.reduce(0) { $0 + $1.messages.count }
        out += "Total messages stored: \(totalMessages)\n"
        out += "(content not included for privacy)\n"
        out += "\n"

        out += "=== Settings ===\n"
        out += "Auto-announce: \(appState.autoAnnounceEnabled)\n"
        out += "Transport mode: \(appState.transportModeEnabled)\n"
        out += "Propagation node: \(appState.propagationNodeEnabled)\n"
        out += "Location sharing: \(appState.locationSharingEnabled)\n"

        if !appState.probeResult.isEmpty {
            out += "\n=== Last Probe ===\n"
            out += appState.probeResult + "\n"
        }

        if !appState.recentOutboundByInterface.isEmpty {
            out += "\n=== Recent Outbound Bytes (pre-framing, hex) ===\n"
            for (ifaceName, hexes) in appState.recentOutboundByInterface.sorted(by: { $0.key < $1.key }) {
                out += "[\(ifaceName)]\n"
                if hexes.isEmpty {
                    out += "  (none yet)\n"
                } else {
                    for (i, h) in hexes.enumerated() {
                        out += "  \(i): \(h)\n"
                    }
                }
            }
        }

        return out
    }

    /// POST the report to paste.rs and return the resulting URL.
    /// paste.rs accepts a raw body and replies with the URL of the new paste.
    static func publishToPasteRs(_ report: String) async throws -> URL {
        var request = URLRequest(url: URL(string: "https://paste.rs")!)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(report.utf8)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PublishError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PublishError.http(http.statusCode)
        }
        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: body), !body.isEmpty else {
            throw PublishError.empty
        }
        return url
    }

    /// POST the report to a ntfy.sh topic. Each POST is delivered to any subscriber
    /// listening on https://ntfy.sh/<topic>/raw. The topic should be unguessable
    /// since anyone with it can read the messages.
    static func publishToNtfy(_ report: String, topic: String) async throws {
        guard let url = URL(string: "https://ntfy.sh/\(topic)") else {
            throw PublishError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("ReticulumMessenger Diagnostics", forHTTPHeaderField: "Title")
        request.setValue("min", forHTTPHeaderField: "Priority") // quiet, no phone notification
        request.setValue("yes", forHTTPHeaderField: "Cache")     // keep last message readable
        request.httpBody = Data(report.utf8)
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PublishError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PublishError.http(http.statusCode)
        }
    }
}
