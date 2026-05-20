// SPDX-License-Identifier: MIT
// ReticulumMessenger — InterfacesView.swift

import SwiftUI

struct InterfacesView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddInterface = false
    @State private var editingInterface: InterfaceInfo?
    @State private var interfaceToDelete: InterfaceInfo?

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
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingInterface = iface
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            interfaceToDelete = iface
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            editingInterface = iface
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
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
        .sheet(item: $editingInterface) { iface in
            InterfaceConfigView(editing: iface)
        }
        .alert("Delete Interface", isPresented: .init(
            get: { interfaceToDelete != nil },
            set: { if !$0 { interfaceToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { interfaceToDelete = nil }
            Button("Delete", role: .destructive) {
                if let iface = interfaceToDelete {
                    Task { await appState.deleteInterface(named: iface.name) }
                    interfaceToDelete = nil
                }
            }
        } message: {
            Text("Remove \"\(interfaceToDelete?.name ?? "")\"? The connection will be closed.")
        }
    }
}
