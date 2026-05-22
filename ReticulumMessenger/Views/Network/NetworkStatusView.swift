// SPDX-License-Identifier: MIT
// ReticulumMessenger — NetworkStatusView.swift

import SwiftUI

struct NetworkStatusView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddInterface = false
    @State private var copiedToast = false

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

                // Identity — Rust engine is the active send/receive path.
                Section("Local Identity") {
                    if !appState.rustLxmfAddress.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Identity Hash") {
                                Text(formatHash(appState.rustIdentityHash))
                                    .monospaced()
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                            LabeledContent("LXMF Address") {
                                Text(appState.rustLxmfAddress)
                                    .monospaced()
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                            Button {
                                UIPasteboard.general.string = appState.rustLxmfAddress
                                withAnimation { copiedToast = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                    withAnimation { copiedToast = false }
                                }
                            } label: {
                                Label("Copy LXMF address", systemImage: "doc.on.doc")
                                    .font(.caption)
                            }
                        }
                    } else {
                        Text("Starting engine…")
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

                // Tools
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
                        DiscoveredPeersView()
                    } label: {
                        Label("Discovered Peers", systemImage: "person.2")
                            .badge(appState.knownPeers.count)
                    }

                    NavigationLink {
                        RNodeView()
                    } label: {
                        Label("RNode Device", systemImage: "antenna.radiowaves.left.and.right")
                    }

                    NavigationLink {
                        TestLabView()
                    } label: {
                        Label("Diagnostics", systemImage: "testtube.2")
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
