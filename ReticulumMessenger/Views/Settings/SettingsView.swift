// SPDX-License-Identifier: MIT
// ReticulumMessenger — SettingsView.swift

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var displayName: String = ""
    @State private var showResetConfirm = false
    @State private var showAnnounceConfirm = false

    var body: some View {
        NavigationStack {
            List {
                // Profile
                Section("Profile") {
                    HStack {
                        if !appState.localIdentityHash.isEmpty {
                            AvatarView(
                                hash: Data(hexString: appState.localIdentityHash) ?? Data(),
                                size: 56
                            )
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Display Name", text: $displayName)
                                .font(.headline)
                                .onSubmit { saveDisplayName() }
                            Text(appState.localIdentityHash.isEmpty ? "..." : String(appState.localIdentityHash.prefix(16)))
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Identity
                Section("Identity") {
                    NavigationLink("Identity Details") {
                        IdentityView()
                    }

                    NavigationLink {
                        QRCodeView()
                    } label: {
                        Label("QR Code", systemImage: "qrcode")
                    }

                    NavigationLink {
                        IdentityExportView()
                    } label: {
                        Label("Backup & Restore", systemImage: "key.viewfinder")
                    }

                    Button("Announce on Network") {
                        Task {
                            do {
                                try await appState.messengerService?.announce(
                                    displayName: displayName.isEmpty ? nil : displayName
                                )
                                showAnnounceConfirm = true
                            } catch {
                                // Announce failed silently — network may be offline
                            }
                        }
                    }
                }

                // Network
                Section("Network") {
                    NavigationLink("Manage Interfaces") {
                        InterfacesView()
                    }

                    NavigationLink {
                        RNodeView()
                    } label: {
                        Label("RNode Device", systemImage: "antenna.radiowaves.left.and.right")
                    }

                    NavigationLink {
                        AnnounceStreamView()
                    } label: {
                        Label("Announce Stream", systemImage: "megaphone")
                    }
                }

                // Mesh Features
                Section {
                    Toggle("Auto-Announce", isOn: Binding(
                        get: { appState.autoAnnounceEnabled },
                        set: { newValue in
                            if newValue {
                                appState.startAutoAnnounce()
                            } else {
                                appState.stopAutoAnnounce()
                            }
                        }
                    ))

                    Toggle("Location Sharing", isOn: Binding(
                        get: { appState.locationSharingEnabled },
                        set: { appState.setLocationSharing($0) }
                    ))

                    Toggle("Transport Mode", isOn: Binding(
                        get: { appState.transportModeEnabled },
                        set: { newValue in
                            Task { await appState.setTransportMode(newValue) }
                        }
                    ))

                    Toggle("Propagation Node", isOn: Binding(
                        get: { appState.propagationNodeEnabled },
                        set: { newValue in
                            Task { await appState.setPropagationNode(newValue) }
                        }
                    ))
                } header: {
                    Text("Mesh Features")
                } footer: {
                    Text("Auto-Announce broadcasts your presence periodically. Transport Mode lets your device relay packets for the mesh. Propagation Node stores messages for offline peers.")
                }

                // Engine selection — Rust engine drives sends/receives when
                // ON; off-mode falls back to the pure-Swift LXMF stack, which
                // is currently incomplete and not recommended.
                Section {
                    Toggle("Use Rust engine (recommended)", isOn: Binding(
                        get: { appState.rustEngineEnabled },
                        set: { appState.setRustEngine($0) }
                    ))
                    if appState.rustEngineEnabled {
                        LabeledContent("Status") {
                            Text(appState.rustEngineStarted ? "Started" : "Starting…")
                                .foregroundStyle(appState.rustEngineStarted ? .green : .orange)
                        }
                        if !appState.rustLxmfAddress.isEmpty {
                            LabeledContent("LXMF Address") {
                                Text(appState.rustLxmfAddress)
                                    .font(.caption2)
                                    .monospaced()
                                    .textSelection(.enabled)
                            }
                        }
                        if let err = appState.rustEngineError {
                            Text(err).font(.caption2).foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Engine")
                } footer: {
                    Text("The Rust engine (Rusticulum + LXMF-rust) is the proven send/receive path. The pure-Swift fallback cannot deliver LXMF reliably yet — leave this ON.")
                }

                // About
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    LabeledContent("Protocol", value: "Reticulum")
                    LabeledContent("Messaging", value: "LXMF")

                    NavigationLink("About Reticulum Messenger") {
                        AboutView()
                    }
                }

                // Danger Zone
                Section {
                    Button("Reset Identity", role: .destructive) {
                        showResetConfirm = true
                    }
                } footer: {
                    Text("Resetting your identity will generate new cryptographic keys. You will no longer be reachable at your current address.")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                displayName = appState.storageService?.loadDisplayName() ?? ""
            }
            .confirmationDialog(
                "Reset Identity?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    Task { await appState.resetIdentity() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will generate a new identity. Your current address will become unreachable. This cannot be undone.")
            }
            .alert("Announced", isPresented: $showAnnounceConfirm) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your presence has been announced on the network.")
            }
        }
    }

    private func saveDisplayName() {
        appState.storageService?.saveDisplayName(displayName.isEmpty ? nil : displayName)
    }

}
