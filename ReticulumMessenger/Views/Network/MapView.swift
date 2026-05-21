// SPDX-License-Identifier: MIT
// ReticulumMessenger — MapView.swift
// Live mesh map showing peer locations and network topology.

import SwiftUI
import MapKit

struct MeshMapView: View {
    @EnvironmentObject var appState: AppState

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedPeer: PeerLocation?
    @State private var showLocationAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $cameraPosition, selection: $selectedPeer) {
                    // Current user location
                    if let loc = appState.telemetryService?.currentLocation {
                        Annotation("Me", coordinate: loc) {
                            ZStack {
                                Circle()
                                    .fill(.blue.opacity(0.25))
                                    .frame(width: 44, height: 44)
                                Circle()
                                    .fill(.blue)
                                    .frame(width: 14, height: 14)
                                Circle()
                                    .stroke(.white, lineWidth: 2)
                                    .frame(width: 14, height: 14)
                            }
                        }
                    }

                    // Peer locations
                    ForEach(peerLocations) { peer in
                        Annotation(peer.displayName ?? peer.shortHash,
                                   coordinate: CLLocationCoordinate2D(latitude: peer.latitude, longitude: peer.longitude),
                                   anchor: .bottom) {
                            PeerMapPin(peer: peer)
                        }
                        .tag(peer)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .mapControls {
                    MapCompass()
                    MapScaleView()
                    MapUserLocationButton()
                }

                // Empty state overlay when peers exist but none share location
                if peerLocations.isEmpty && !appState.knownPeers.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "location.slash")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("No peers sharing location")
                                .font(.subheadline.bold())
                            Text("\(appState.knownPeers.count) peer\(appState.knownPeers.count == 1 ? "" : "s") discovered on the mesh but none are broadcasting GPS coordinates.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)

                        // Compact peer list
                        discoveredPeersList
                        Spacer()
                    }
                }

                // Overlay info
                VStack {
                    Spacer()
                    HStack {
                        peerCountBadge
                        Spacer()
                        if appState.telemetryService?.locationEnabled == true {
                            locationSharingBadge
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Mesh Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            cameraPosition = .automatic
                        } label: {
                            Label("Fit All Peers", systemImage: "arrow.up.left.and.arrow.down.right")
                        }

                        Button {
                            toggleLocationSharing()
                        } label: {
                            Label(
                                appState.telemetryService?.locationEnabled == true ? "Stop Sharing Location" : "Share My Location",
                                systemImage: appState.telemetryService?.locationEnabled == true ? "location.slash" : "location"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Location Access", isPresented: $showLocationAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Location access is required to share your position on the mesh map. Please enable it in Settings.")
            }
            .sheet(item: $selectedPeer) { peer in
                PeerLocationDetailView(peer: peer)
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Computed

    private var peerLocations: [PeerLocation] {
        appState.telemetryService?.peerLocations ?? []
    }

    // MARK: - Subviews

    private var peerCountBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.2.fill")
                .font(.caption2)
            Text("\(peerLocations.count) on map, \(appState.knownPeers.count) discovered")
                .font(.caption.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var discoveredPeersList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(appState.knownPeers.prefix(8)), id: \.destinationHash) { peer in
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(peer.displayName.isEmpty ? peer.shortHash : peer.displayName)
                            .font(.caption.bold())
                        Text(peer.shortHash)
                            .font(.system(size: 9))
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(peer.lastSeen, style: .relative)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                if peer.destinationHash != appState.knownPeers.prefix(8).last?.destinationHash {
                    Divider().padding(.leading, 32)
                }
            }
            if appState.knownPeers.count > 8 {
                Text("+\(appState.knownPeers.count - 8) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var locationSharingBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "location.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
            Text("Sharing")
                .font(.caption.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Actions

    private func toggleLocationSharing() {
        guard let telemetry = appState.telemetryService else { return }

        if telemetry.locationEnabled {
            telemetry.stopLocationUpdates()
        } else {
            let status = telemetry.locationAuthStatus
            if status == .denied || status == .restricted {
                showLocationAlert = true
            } else {
                telemetry.startLocationUpdates()
            }
        }
    }
}

// MARK: - Peer Map Pin

struct PeerMapPin: View {
    let peer: PeerLocation

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 32, height: 32)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
            }
            Triangle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 6)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
        }
    }
}

// MARK: - Peer Location Detail

struct PeerLocationDetailView: View {
    let peer: PeerLocation
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(Color.accentColor)
                            Text(peer.displayName ?? "Unknown Peer")
                                .font(.title3.bold())
                            Text(peer.peerHash)
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Location") {
                    LabeledContent("Latitude") {
                        Text(String(format: "%.6f°", peer.latitude))
                            .monospaced()
                    }
                    LabeledContent("Longitude") {
                        Text(String(format: "%.6f°", peer.longitude))
                            .monospaced()
                    }
                    LabeledContent("Last Update") {
                        Text(peer.lastUpdate, style: .relative)
                    }
                }

                Section {
                    Button {
                        let coordinate = "\(peer.latitude),\(peer.longitude)"
                        if let url = URL(string: "maps://?q=\(peer.displayName ?? "Peer")&ll=\(coordinate)") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open in Maps", systemImage: "map")
                    }
                }
            }
            .navigationTitle("Peer Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - PeerLocation Hashable

extension PeerLocation: Hashable {
    static func == (lhs: PeerLocation, rhs: PeerLocation) -> Bool {
        lhs.peerHash == rhs.peerHash
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(peerHash)
    }
}
