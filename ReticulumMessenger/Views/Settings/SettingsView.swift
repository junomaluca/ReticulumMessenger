// SPDX-License-Identifier: MIT
// ReticulumMessenger — SettingsView.swift

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var displayName: String = ""
    @State private var showResetConfirm = false
    @State private var showAnnounceConfirm = false
    @State private var selfTestTarget: String = ""
    @State private var showSelfTest = false

    var body: some View {
        NavigationStack {
            List {
                // Profile
                Section("Profile") {
                    HStack {
                        if !appState.rustIdentityHash.isEmpty {
                            AvatarView(
                                hash: Data(hexString: appState.rustIdentityHash) ?? Data(),
                                size: 56
                            )
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Display Name", text: $displayName)
                                .font(.headline)
                                .onSubmit { saveDisplayName() }
                            Text(appState.rustLxmfAddress.isEmpty
                                 ? (appState.rustIdentityHash.isEmpty ? "..." : String(appState.rustIdentityHash.prefix(16)))
                                 : appState.rustLxmfAddress)
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                // Identity
                Section("Identity") {
                    NavigationLink {
                        IdentityView()
                    } label: {
                        Label("Identity Details", systemImage: "person.text.rectangle")
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

                    Button {
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
                    } label: {
                        Label("Announce on Network", systemImage: "dot.radiowaves.left.and.right")
                    }
                }

                // Network
                Section("Network") {
                    NavigationLink {
                        InterfacesView()
                    } label: {
                        Label("Manage Interfaces", systemImage: "rectangle.connected.to.line.below")
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

                // Self-Test
                Section {
                    NavigationLink {
                        SelfTestView()
                    } label: {
                        Label("Attachment Self-Test", systemImage: "checkmark.shield")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Send test attachments to a target address to verify outbound delivery.")
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
