// SPDX-License-Identifier: MIT
// ReticulumMessenger — NetworkStatusView.swift

import SwiftUI

struct NetworkStatusView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddInterface = false
    @State private var copiedToast = false
    @State private var isPublishing = false
    @State private var publishedURL: URL?
    @State private var publishError: String?

    var body: some View {
        NavigationStack {
            List {
                // Status Overview
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: appState.networkStatus.systemImage)
                            .font(.largeTitle)
                            .foregroundStyle(appState.networkStatus.color)
                            .symbolEffect(.variableColor, isActive: appState.networkStatus == .connecting)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(appState.networkStatus.label)
                                .font(.headline)
                            Text("\(appState.interfaces.filter(\.isOnline).count) interface(s) online")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Identity
                Section("Local Identity") {
                    if !appState.localIdentityHash.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Identity Hash") {
                                Text(formatHash(appState.localIdentityHash))
                                    .monospaced()
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                            LabeledContent("LXMF Address") {
                                Text(formatHash(appState.deliveryHash))
                                    .monospaced()
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    } else {
                        Text("Initializing...")
                            .foregroundStyle(.secondary)
                    }
                }

                // Interfaces
                Section {
                    if appState.interfaces.isEmpty {
                        Text("No interfaces configured")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.interfaces) { iface in
                            InterfaceRow(interface: iface)
                        }
                    }
                } header: {
                    HStack {
                        Text("Interfaces")
                        Spacer()
                        Button {
                            showAddInterface = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.body)
                        }
                    }
                }

                // Packet Diagnostics
                if !appState.packetDiagnostics.isEmpty {
                    Section {
                        Text(appState.packetDiagnostics)
                            .font(.caption)
                            .monospaced()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                UIPasteboard.general.string = appState.packetDiagnostics
                                withAnimation { copiedToast = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                    withAnimation { copiedToast = false }
                                }
                            }
                        Button {
                            publishDiagnostics()
                        } label: {
                            HStack {
                                if isPublishing {
                                    ProgressView().controlSize(.small)
                                    Text("Publishing…")
                                } else {
                                    Label("Publish Diagnostics", systemImage: "square.and.arrow.up")
                                }
                            }
                        }
                        .disabled(isPublishing)

                        Toggle(isOn: Binding(
                            get: { appState.autoPublishDiagnosticsEnabled },
                            set: { appState.setAutoPublishDiagnostics($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-publish every 1 min")
                                Text("Posts to paste.rs in the background")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Toggle(isOn: Binding(
                            get: { appState.streamDiagnosticsEnabled },
                            set: { appState.setStreamDiagnostics($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Stream to ntfy.sh (every 10s)")
                                Text("Pushes diagnostics for live remote monitoring")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if appState.streamDiagnosticsEnabled && !appState.ntfyTopic.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Stream topic")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Text("ntfy.sh/" + appState.ntfyTopic)
                                        .font(.caption)
                                        .monospaced()
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button {
                                        UIPasteboard.general.string = "https://ntfy.sh/" + appState.ntfyTopic + "/raw"
                                        withAnimation { copiedToast = true }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                            withAnimation { copiedToast = false }
                                        }
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                if let ts = appState.lastStreamAt {
                                    Text("Last push \(ts, style: .relative) ago")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }

                        if let urlString = appState.lastDiagnosticsURL,
                           let url = URL(string: urlString) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Latest URL")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Text(urlString)
                                        .font(.caption)
                                        .monospaced()
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button {
                                        UIPasteboard.general.string = urlString
                                        withAnimation { copiedToast = true }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                            withAnimation { copiedToast = false }
                                        }
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                    Link(destination: url) {
                                        Image(systemName: "arrow.up.right.square")
                                    }
                                }
                                if let ts = appState.lastDiagnosticsAt {
                                    Text("Published \(ts, style: .relative) ago")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Packet Stats")
                            Spacer()
                            if copiedToast {
                                Text("Copied!")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                                    .transition(.opacity)
                            } else {
                                Text("tap to copy")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                // Network Probe
                Section("Diagnostics") {
                    Button {
                        Task {
                            await appState.probeFirstPeer()
                        }
                    } label: {
                        Label("Probe First Peer", systemImage: "stethoscope")
                    }
                    .disabled(appState.knownPeers.isEmpty)

                    if !appState.probeResult.isEmpty {
                        Text(appState.probeResult)
                            .font(.caption)
                            .monospaced()
                    }
                }

                // Quick Links
                Section("Tools") {
                    NavigationLink {
                        NetworkGraphView()
                    } label: {
                        Label("Mesh Topology", systemImage: "point.3.connected.trianglepath.dotted")
                    }

                    NavigationLink {
                        AnnounceStreamView()
                    } label: {
                        Label("Announce Stream", systemImage: "megaphone")
                            .badge(appState.announceStream.count)
                    }

                    NavigationLink {
                        RNodeView()
                    } label: {
                        Label("RNode Device", systemImage: "antenna.radiowaves.left.and.right")
                    }

                    NavigationLink {
                        TestLabView()
                    } label: {
                        Label("Test Lab", systemImage: "testtube.2")
                    }
                }

                // Known Peers
                Section("Discovered Peers") {
                    if appState.knownPeers.isEmpty {
                        Text("No peers discovered yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.knownPeers) { peer in
                            HStack {
                                AvatarView(hash: peer.destinationHash, size: 36)
                                VStack(alignment: .leading) {
                                    Text(peer.displayName)
                                        .font(.body)
                                    Text(peer.shortHash)
                                        .font(.caption)
                                        .monospaced()
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(peer.lastSeen, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Network")
            .sheet(isPresented: $showAddInterface) {
                InterfaceConfigView()
            }
            .refreshable {
                await appState.refreshNetworkStatus()
            }
            .alert("Diagnostics Published", isPresented: .init(
                get: { publishedURL != nil },
                set: { if !$0 { publishedURL = nil } }
            )) {
                Button("OK", role: .cancel) { publishedURL = nil }
            } message: {
                Text("URL copied to clipboard:\n\(publishedURL?.absoluteString ?? "")")
            }
            .alert("Publish Failed", isPresented: .init(
                get: { publishError != nil },
                set: { if !$0 { publishError = nil } }
            )) {
                Button("OK", role: .cancel) { publishError = nil }
            } message: {
                Text(publishError ?? "")
            }
        }
    }

    private func publishDiagnostics() {
        guard !isPublishing else { return }
        isPublishing = true
        let report = DiagnosticsService.buildReport(appState: appState)
        Task {
            defer { Task { @MainActor in isPublishing = false } }
            do {
                let url = try await DiagnosticsService.publishToPasteRs(report)
                await MainActor.run {
                    UIPasteboard.general.string = url.absoluteString
                    publishedURL = url
                }
            } catch {
                await MainActor.run {
                    publishError = error.localizedDescription
                }
            }
        }
    }

    private func formatHash(_ hash: String) -> String {
        guard hash.count > 8 else { return hash }
        return String(hash.prefix(8)) + "..." + String(hash.suffix(8))
    }
}

// MARK: - Interface Row

struct InterfaceRow: View {
    let interface: InterfaceInfo

    var body: some View {
        HStack {
            Circle()
                .fill(interface.isOnline ? .green : .red)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(interface.name)
                    .font(.body)
                Text(interface.type)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(interface.statusText)
                    .font(.caption)
                    .foregroundStyle(interface.isOnline ? .green : .secondary)
                HStack(spacing: 8) {
                    Label(InterfaceInfo.formatBytes(interface.bytesSent), systemImage: "arrow.up")
                    Label(InterfaceInfo.formatBytes(interface.bytesReceived), systemImage: "arrow.down")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
