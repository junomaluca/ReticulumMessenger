// SPDX-License-Identifier: MIT
// ReticulumMessenger — TestLabView.swift
// Stress-test panel: sends a battery of LXMF messages of varying size and
// payload type to a configured peer, records per-send outcome, and exposes
// the results in-app + via the diagnostics stream.

import SwiftUI
import ReticulumKit
import LXMFKit

struct TestLabView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("testLab.peerHex") private var peerHex: String = ""
    @AppStorage("testLab.useRustEngine") private var useRustEngine: Bool = true
    @State private var results: [TestResult] = []
    @State private var running = false
    @State private var currentLabel: String?

    var body: some View {
        Form {
            Section {
                TextField("Peer LXMF address (16-byte hex)", text: $peerHex)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption)
                    .monospaced()
                Button {
                    pasteAddress()
                } label: {
                    Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                }
                Button {
                    pickFromAnnounces()
                } label: {
                    Label("Pick from recent announces", systemImage: "megaphone")
                }
                Button {
                    peerHex = "07e15fb1284a4aa9419149bf891bfec3"
                } label: {
                    Label("Use Sideband (this Mac)", systemImage: "desktopcomputer")
                }
                Button {
                    peerHex = "2db1b80d36dba6ae44e221696261cb38"
                } label: {
                    Label("Use Claude-Echo bot", systemImage: "bubble.left.and.bubble.right")
                }
            } header: {
                Text("Test peer")
            } footer: {
                Text("Sideband (this Mac): 07e15fb1284a4aa9419149bf891bfec3\nClaude-Echo bot: 2db1b80d36dba6ae44e221696261cb38")
                    .font(.caption2)
                    .monospaced()
            }

            Section {
                Toggle(isOn: Binding(
                    get: { appState.rustEngineEnabled },
                    set: { appState.setRustEngine($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Rust engine (experimental)")
                        Text("Routes sends through Rusticulum + LXMF-rust FFI")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Send via Rust engine", isOn: $useRustEngine)
                    .disabled(!appState.rustEngineStarted)
                if appState.rustEngineEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rust LXMF: \(appState.rustLxmfAddress.isEmpty ? "(starting…)" : appState.rustLxmfAddress)")
                            .font(.caption).monospaced().textSelection(.enabled)
                        Text("Rust Identity: \(appState.rustIdentityHash.isEmpty ? "(starting…)" : appState.rustIdentityHash)")
                            .font(.caption).monospaced().textSelection(.enabled)
                        if let e = appState.rustEngineError {
                            Text("Error: \(e)").font(.caption2).foregroundStyle(.red)
                        }
                        if !appState.rustRecentInbound.isEmpty {
                            Text("Recent inbound (Rust):").font(.caption2).foregroundStyle(.secondary)
                            ForEach(Array(appState.rustRecentInbound.enumerated()), id: \.offset) { _, line in
                                Text("• \(line)").font(.caption2).lineLimit(2)
                            }
                        }
                    }
                }
            } header: { Text("Rust engine") }

            Section("Individual tests") {
                testButton("Send 1 tiny text (20 B)") {
                    await runOne(label: "tiny-text", body: { try await sendText(content: "ping " + String(Int.random(in: 1000...9999))) })
                }
                testButton("Send 10 small texts") {
                    for i in 0..<10 {
                        await runOne(label: "small-text-\(i+1)") {
                            try await sendText(content: "small #\(i+1) at \(Date().timeIntervalSince1970)")
                        }
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
                testButton("Send 1 KB text") { await runOne(label: "text-1KB") { try await sendText(content: String(repeating: "A", count: 1024)) } }
                testButton("Send 5 KB text") { await runOne(label: "text-5KB") { try await sendText(content: String(repeating: "B", count: 5 * 1024)) } }
                testButton("Send 1 KB attachment") { await runOne(label: "attach-1KB") { try await sendAttachment(size: 1024, mime: "application/octet-stream", name: "test1k.bin") } }
                testButton("Send 10 KB attachment") { await runOne(label: "attach-10KB") { try await sendAttachment(size: 10 * 1024, mime: "image/png", name: "test10k.png") } }
                testButton("Send 100 KB attachment") { await runOne(label: "attach-100KB") { try await sendAttachment(size: 100 * 1024, mime: "image/jpeg", name: "test100k.jpg") } }
                testButton("Send 50 KB voice memo") { await runOne(label: "voice-50KB") { try await sendAttachment(size: 50 * 1024, mime: "audio/x-caf", name: "test50k.caf") } }
            }

            Section("Suite") {
                Button {
                    Task { await runSuite() }
                } label: {
                    if running {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Running… \(currentLabel ?? "")")
                        }
                    } else {
                        Label("Run all tests", systemImage: "play.fill")
                    }
                }
                .disabled(running || peerHash == nil)
                Button(role: .destructive) {
                    results.removeAll()
                } label: {
                    Label("Clear results", systemImage: "trash")
                }
                .disabled(results.isEmpty)
            }

            if !results.isEmpty {
                Section("Results (newest last)") {
                    ForEach(results) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(r.ok ? .green : .red)
                                Text(r.label)
                                    .font(.caption)
                                    .monospaced()
                                Spacer()
                                Text(String(format: "%.2fs", r.elapsed))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let err = r.error {
                                Text(err)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Test Lab")
    }

    // MARK: - Test runner

    private func testButton(_ label: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task {
                running = true
                currentLabel = label
                await action()
                currentLabel = nil
                running = false
            }
        } label: {
            Text(label).font(.callout)
        }
        .disabled(running || peerHash == nil)
    }

    private func runSuite() async {
        running = true
        currentLabel = "suite"
        let plan: [(String, () async throws -> Void)] = [
            ("tiny-text", { try await sendText(content: "suite ping") }),
            ("small-text-x5", {
                for i in 0..<5 {
                    try await sendText(content: "suite-small #\(i+1)")
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }),
            ("text-1KB", { try await sendText(content: String(repeating: "A", count: 1024)) }),
            ("text-5KB", { try await sendText(content: String(repeating: "B", count: 5 * 1024)) }),
            ("attach-1KB", { try await sendAttachment(size: 1024, mime: "application/octet-stream", name: "s1k.bin") }),
            ("attach-10KB", { try await sendAttachment(size: 10 * 1024, mime: "image/png", name: "s10k.png") }),
            ("attach-100KB", { try await sendAttachment(size: 100 * 1024, mime: "image/jpeg", name: "s100k.jpg") }),
            ("voice-50KB", { try await sendAttachment(size: 50 * 1024, mime: "audio/x-caf", name: "s50k.caf") }),
        ]
        for (label, action) in plan {
            currentLabel = label
            await runOne(label: label, body: action)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        currentLabel = nil
        running = false
    }

    private func runOne(label: String, body: () async throws -> Void) async {
        let started = Date()
        do {
            try await body()
            results.append(TestResult(label: label, ok: true, elapsed: Date().timeIntervalSince(started), error: nil))
        } catch {
            results.append(TestResult(label: label, ok: false, elapsed: Date().timeIntervalSince(started), error: error.localizedDescription))
        }
    }

    // MARK: - Sending helpers

    private var peerHash: Data? {
        let trimmed = peerHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 32, trimmed.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        var data = Data(capacity: 16)
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex {
            let next = trimmed.index(idx, offsetBy: 2)
            if let b = UInt8(trimmed[idx..<next], radix: 16) { data.append(b) } else { return nil }
            idx = next
        }
        return data
    }

    private func sendText(content: String) async throws {
        guard let hash = peerHash else { throw NSError(domain: "TestLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid peer address"]) }
        if useRustEngine {
            try await appState.rustSendText(to: peerHex, content: content)
        } else {
            try await appState.sendMessage(content: content, to: hash)
        }
    }

    private func sendAttachment(size: Int, mime: String, name: String) async throws {
        guard let hash = peerHash else { throw NSError(domain: "TestLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid peer address"]) }
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, size, buf.baseAddress!)
        }
        if useRustEngine {
            try await appState.rustSendAttachment(to: peerHex, data: bytes,
                                                  mime: mime, filename: name)
        } else {
            try await appState.sendAttachment(data: bytes, mimeType: mime, filename: name, to: hash)
        }
    }

    private func pasteAddress() {
        if let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) {
            peerHex = s.lowercased()
        }
    }

    private func pickFromAnnounces() {
        if let first = appState.announceStream.first(where: { $0.destinationHash != nil }),
           let dest = first.destinationHash {
            peerHex = dest.map { String(format: "%02x", $0) }.joined()
        }
    }
}

private struct TestResult: Identifiable {
    let id = UUID()
    let label: String
    let ok: Bool
    let elapsed: TimeInterval
    let error: String?
}
