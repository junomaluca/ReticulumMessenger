// SPDX-License-Identifier: MIT
// ReticulumMessenger — AboutView.swift

import SwiftUI

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // App Icon / Title
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)

                    Text("Reticulum Messenger")
                        .font(.title.bold())

                    Text("v0.2.0")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                // Description
                VStack(alignment: .leading, spacing: 16) {
                    infoSection(
                        title: "About",
                        text: "Reticulum Messenger is an open-source iOS client for the Reticulum Network Stack. It uses the LXMF protocol to send and receive encrypted messages over mesh networks, completely independent of traditional internet infrastructure."
                    )

                    infoSection(
                        title: "Reticulum",
                        text: "Reticulum is a cryptography-based networking protocol designed for unstable and unreliable networks. It provides encrypted, authenticated communication over any medium — from WiFi and cellular to LoRa radio and serial links."
                    )

                    infoSection(
                        title: "LXMF",
                        text: "LXMF (Lightweight Extensible Message Format) is a messaging protocol built on Reticulum. It supports direct delivery, store-and-forward propagation, and works across any combination of network interfaces."
                    )

                    infoSection(
                        title: "Privacy",
                        text: "All messages are end-to-end encrypted using modern elliptic curve cryptography (X25519 + Ed25519). Your identity exists only on your device — there are no accounts, servers, or phone numbers."
                    )

                    infoSection(
                        title: "Open Source",
                        text: "This app is open source under the MIT license. Contributions are welcome! Visit the GitHub repository to get involved."
                    )
                }
                .padding(.horizontal)

                // Links
                VStack(spacing: 12) {
                    linkButton(
                        title: "Reticulum Network",
                        url: "https://reticulum.network",
                        icon: "globe"
                    )
                    linkButton(
                        title: "LXMF Documentation",
                        url: "https://github.com/markqvist/lxmf",
                        icon: "doc.text"
                    )
                    linkButton(
                        title: "Sideband (Android)",
                        url: "https://github.com/markqvist/Sideband",
                        icon: "apps.iphone"
                    )
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func linkButton(title: String, url: String, icon: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 24)
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
            }
            .padding()
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
        }
        .tint(.primary)
    }
}
