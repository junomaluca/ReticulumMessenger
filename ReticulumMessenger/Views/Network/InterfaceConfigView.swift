// SPDX-License-Identifier: MIT
// ReticulumMessenger — InterfaceConfigView.swift

import SwiftUI

struct InterfaceConfigView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    /// When non-nil, we are editing an existing interface.
    var editing: InterfaceInfo?

    @State private var interfaceType = 0 // 0 = TCP, 1 = UDP
    @State private var name = ""
    @State private var host = ""
    @State private var port = "4242"
    @State private var listenPort = ""
    @State private var isConnecting = false
    @State private var showError = false
    @State private var errorMessage = ""

    private var isEditing: Bool { editing != nil }

    var body: some View {
        NavigationStack {
            Form {
                // Interface type selector
                Section {
                    Picker("Interface Type", selection: $interfaceType) {
                        Text("TCP").tag(0)
                        Text("UDP").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isEditing)
                }

                Section {
                    TextField("Interface Name", text: $name)
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("A friendly name for this connection (e.g., \"Home Node\").")
                }

                if interfaceType == 0 {
                    tcpSection
                } else {
                    udpSection
                }

                // Quick presets (only for new interfaces)
                if !isEditing {
                    Section {
                        Text("The Reticulum Testnet is available at **amsterdam.connect.reticulum.network:4965**")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Use Testnet") {
                            name = "RNS Testnet"
                            host = "amsterdam.connect.reticulum.network"
                            port = "4965"
                            interfaceType = 0
                        }
                        .font(.callout)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Interface" : "Add Interface")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Button(isEditing ? "Save" : "Connect") { connect() }
                            .disabled(!isValid)
                    }
                }
            }
            .alert("Connection Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                if let iface = editing {
                    name = iface.name
                    if iface.type.contains("TCP") {
                        interfaceType = 0
                    } else if iface.type.contains("UDP") {
                        interfaceType = 1
                    }
                    // Try to populate host/port from saved configs
                    if let config = appState.savedInterfaceConfig(named: iface.name) {
                        host = config.host ?? ""
                        if let p = config.port { port = "\(p)" }
                    }
                }
            }
        }
    }

    // MARK: - TCP Section

    private var tcpSection: some View {
        Section {
            TextField("Host", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            TextField("Port", text: $port)
                .keyboardType(.numberPad)
        } header: {
            Text("TCP Connection")
        } footer: {
            Text("Connect to a Reticulum transport node. The default port is 4242.")
        }
    }

    // MARK: - UDP Section

    private var udpSection: some View {
        Section {
            TextField("Remote Host (optional)", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            TextField("Remote Port", text: $port)
                .keyboardType(.numberPad)

            TextField("Listen Port (optional)", text: $listenPort)
                .keyboardType(.numberPad)
        } header: {
            Text("UDP Connection")
        } footer: {
            Text("Leave the remote host empty for receive-only/broadcast mode. Listen port defaults to the remote port if not specified.")
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        if interfaceType == 0 {
            return !name.isEmpty && !host.isEmpty && UInt16(port) != nil
        } else {
            return !name.isEmpty && UInt16(port) != nil
        }
    }

    // MARK: - Connection

    private func connect() {
        guard let portNum = UInt16(port) else { return }
        isConnecting = true

        Task {
            do {
                if isEditing {
                    let type: ReticulumKit.RNSInterfaceConfig.InterfaceType = interfaceType == 0 ? .tcpClient : .udp
                    try await appState.updateInterface(
                        oldName: editing!.name,
                        name: name,
                        host: host,
                        port: portNum,
                        type: type
                    )
                } else if interfaceType == 0 {
                    try await appState.addTCPInterface(name: name, host: host, port: portNum)
                } else {
                    let listen = UInt16(listenPort) ?? portNum
                    try await appState.addUDPInterface(
                        name: name,
                        host: host.isEmpty ? nil : host,
                        port: portNum,
                        listenPort: listen
                    )
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isConnecting = false
        }
    }
}
