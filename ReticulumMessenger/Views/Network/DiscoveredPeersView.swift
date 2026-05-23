// SPDX-License-Identifier: MIT
// ReticulumMessenger — DiscoveredPeersView.swift
// Lists every peer the local stack has seen an announce for, newest first.

import SwiftUI

struct DiscoveredPeersView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            if appState.knownPeers.isEmpty {
                Section {
                    Text("No peers discovered yet")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Peers appear here as their announces reach the device. Connect an interface to start receiving announces.")
                }
            } else {
                Section {
                    ForEach(appState.knownPeers) { peer in
                        HStack {
                            AvatarView(hash: peer.destinationHash, size: 36)
                            VStack(alignment: .leading) {
                                Text(appState.customDisplayName(forPeerHash: peer.destinationHash) ?? peer.displayName)
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
                } header: {
                    Text("\(appState.knownPeers.count) peer\(appState.knownPeers.count == 1 ? "" : "s")")
                }
            }
        }
        .navigationTitle("Discovered Peers")
        .refreshable {
            await appState.refreshNetworkStatus()
        }
    }
}
