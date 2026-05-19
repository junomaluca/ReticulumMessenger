// SPDX-License-Identifier: MIT
// ReticulumMessenger — NetworkStatusView.swift

import SwiftUI

struct NetworkStatusView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddInterface = false

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

                // Quick Links
                Section("Tools") {
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
                // Trigger a refresh
                try? await Task.sleep(nanoseconds: 500_000_000)
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
