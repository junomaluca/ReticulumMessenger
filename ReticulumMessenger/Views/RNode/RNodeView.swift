// SPDX-License-Identifier: MIT
// ReticulumMessenger — RNodeView.swift
// RNode device management: scanning, connecting, and configuration.

import SwiftUI
import ReticulumKit

struct RNodeView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false
    @State private var discoveredDevices: [RNodeInterface.DiscoveredRNode] = []
    @State private var showConfig = false
    @State private var selectedConfig: RNodeConfig = .balanced

    var body: some View {
        List {
            // Connected RNode
            if let rnode = appState.connectedRNode {
                Section("Connected Device") {
                    connectedDeviceView(rnode)
                }

                Section("Radio Statistics") {
                    radioStatsView(rnode)
                }

                Section("Radio Configuration") {
                    radioConfigView
                }
            }

            // Scanning
            Section {
                if isScanning {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Scanning for RNode devices...")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(discoveredDevices) { device in
                    Button {
                        connectToDevice(device)
                    } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.accentColor)
                                .frame(width: 32)
                            VStack(alignment: .leading) {
                                Text(device.name)
                                    .font(.body)
                                Text("Signal: \(device.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                }
            } header: {
                HStack {
                    Text("Available Devices")
                    Spacer()
                    Button(isScanning ? "Stop" : "Scan") {
                        toggleScanning()
                    }
                    .font(.caption)
                }
            }

            // Presets
            Section("Quick Presets") {
                presetButton("Long Range", config: .longRange,
                             desc: "SF12, 125kHz — Maximum range, slow speed")
                presetButton("Balanced", config: .balanced,
                             desc: "SF9, 125kHz — Good range and speed")
                presetButton("Fast", config: .fast,
                             desc: "SF7, 250kHz — Short range, fast speed")
            }
        }
        .navigationTitle("RNode")
        .toolbar {
            if appState.connectedRNode != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Disconnect") {
                        Task { await appState.disconnectRNode() }
                    }
                    .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Subviews

    private func connectedDeviceView(_ rnode: RNodeInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text(rnode.name)
                        .font(.headline)
                    if let fw = rnode.firmwareVersion {
                        Text("Firmware: \(fw)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let battery = rnode.batteryLevel {
                    Label("\(battery)%", systemImage: batteryIcon(battery))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Label(rnode.config.frequencyString, systemImage: "wave.3.right")
                Spacer()
                Label("SF\(rnode.config.spreadingFactor)", systemImage: "chart.bar")
                Spacer()
                Label(rnode.config.bandwidthString, systemImage: "arrow.left.and.right")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func radioStatsView(_ rnode: RNodeInfo) -> some View {
        Group {
            if let rssi = rnode.lastRSSI {
                LabeledContent("Last RSSI") {
                    Text("\(rssi) dBm")
                        .foregroundStyle(rssiColor(rssi))
                }
            }
            if let snr = rnode.lastSNR {
                LabeledContent("Last SNR") {
                    Text(String(format: "%.1f dB", snr))
                }
            }
            LabeledContent("TX Power") {
                Text("\(rnode.config.txPower) dBm")
            }
            LabeledContent("Radio") {
                Text(rnode.radioOnline ? "Online" : "Offline")
                    .foregroundStyle(rnode.radioOnline ? .green : .red)
            }
        }
    }

    private var radioConfigView: some View {
        Group {
            Picker("Frequency", selection: $selectedConfig.frequency) {
                Text("433 MHz").tag(UInt32(433_000_000))
                Text("868 MHz").tag(UInt32(868_000_000))
                Text("915 MHz").tag(UInt32(915_000_000))
                Text("923 MHz").tag(UInt32(923_000_000))
            }

            Picker("Bandwidth", selection: $selectedConfig.bandwidth) {
                Text("7.8 kHz").tag(UInt32(7_800))
                Text("15.6 kHz").tag(UInt32(15_600))
                Text("31.25 kHz").tag(UInt32(31_250))
                Text("62.5 kHz").tag(UInt32(62_500))
                Text("125 kHz").tag(UInt32(125_000))
                Text("250 kHz").tag(UInt32(250_000))
                Text("500 kHz").tag(UInt32(500_000))
            }

            Picker("Spreading Factor", selection: $selectedConfig.spreadingFactor) {
                ForEach(7...12, id: \.self) { sf in
                    Text("SF\(sf)").tag(UInt8(sf))
                }
            }

            Picker("Coding Rate", selection: $selectedConfig.codingRate) {
                Text("4/5").tag(UInt8(5))
                Text("4/6").tag(UInt8(6))
                Text("4/7").tag(UInt8(7))
                Text("4/8").tag(UInt8(8))
            }

            Stepper("TX Power: \(selectedConfig.txPower) dBm",
                    value: $selectedConfig.txPower, in: 2...22)

            Button("Apply Configuration") {
                Task { await appState.configureRNode(selectedConfig) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func presetButton(_ title: String, config: RNodeConfig, desc: String) -> some View {
        Button {
            selectedConfig = config
            Task { await appState.configureRNode(config) }
        } label: {
            VStack(alignment: .leading) {
                Text(title).font(.body)
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
        .tint(.primary)
    }

    // MARK: - Actions

    private func toggleScanning() {
        if isScanning {
            appState.stopRNodeScan()
            isScanning = false
        } else {
            discoveredDevices = []
            appState.startRNodeScan { device in
                if !discoveredDevices.contains(where: { $0.id == device.id }) {
                    discoveredDevices.append(device)
                }
            }
            isScanning = true
        }
    }

    private func connectToDevice(_ device: RNodeInterface.DiscoveredRNode) {
        isScanning = false
        Task {
            try? await appState.connectRNode(deviceId: device.id, name: device.name)
        }
    }

    // MARK: - Helpers

    private func batteryIcon(_ level: UInt8) -> String {
        switch level {
        case 0..<20: return "battery.0percent"
        case 20..<50: return "battery.25percent"
        case 50..<80: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func rssiColor(_ rssi: Int) -> Color {
        switch rssi {
        case -60...0: return .green
        case -90...(-61): return .orange
        default: return .red
        }
    }
}
