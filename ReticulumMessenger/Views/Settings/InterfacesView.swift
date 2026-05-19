// SPDX-License-Identifier: MIT
// ReticulumMessenger — InterfacesView.swift

import SwiftUI

struct InterfacesView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddInterface = false

    var body: some View {
        List {
            if appState.interfaces.isEmpty {
                ContentUnavailableView {
                    Label("No Interfaces", systemImage: "network.slash")
                } description: {
                    Text("Add a TCP interface to connect to the Reticulum network.")
                }
            } else {
                ForEach(appState.interfaces) { iface in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Circle()
                                .fill(iface.isOnline ? .green : .red)
                                .frame(width: 10, height: 10)
                            Text(iface.name)
                                .font(.headline)
                        }

                        Grid(alignment: .leading, horizontalSpacing: 16) {
                            GridRow {
                                Text("Type")
                                    .foregroundStyle(.secondary)
                                Text(iface.type)
                            }
                            GridRow {
                                Text("Status")
                                    .foregroundStyle(.secondary)
                                Text(iface.statusText)
                            }
                            GridRow {
                                Text("Sent")
                                    .foregroundStyle(.secondary)
                                Text(InterfaceInfo.formatBytes(iface.bytesSent))
                            }
                            GridRow {
                                Text("Received")
                                    .foregroundStyle(.secondary)
                                Text(InterfaceInfo.formatBytes(iface.bytesReceived))
                            }
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Interfaces")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddInterface = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddInterface) {
            InterfaceConfigView()
        }
    }
}
