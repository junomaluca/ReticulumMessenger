// SPDX-License-Identifier: MIT
// ReticulumMessenger — InterfaceConfigView.swift

import SwiftUI

struct InterfaceConfigView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "4242"
    @State private var isConnecting = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Interface Name", text: $name)
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("A friendly name for this connection (e.g., \"Home Node\").")
                }

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

                Section {
                    Text("The Reticulum Testnet is available at **amsterdam.connect.reticulum.network:4965**")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Use Testnet") {
                        name = "RNS Testnet"
                        host = "amsterdam.connect.reticulum.network"
                        port = "4965"
                    }
                    .font(.callout)
                }
            }
            .navigationTitle("Add Interface")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Button("Connect") { connect() }
                            .disabled(!isValid)
                    }
                }
            }
            .alert("Connection Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var isValid: Bool {
        !name.isEmpty && !host.isEmpty && UInt16(port) != nil
    }

    private func connect() {
        guard let portNum = UInt16(port) else { return }
        isConnecting = true

        Task {
            do {
                try await appState.addTCPInterface(name: name, host: host, port: portNum)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isConnecting = false
        }
    }
}
