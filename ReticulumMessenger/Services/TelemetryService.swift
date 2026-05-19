// SPDX-License-Identifier: MIT
// ReticulumMessenger — TelemetryService.swift
// Location sharing, telemetry collection, and peer position tracking.

import Foundation
import UIKit
import CoreLocation
import Combine

/// Manages device telemetry collection and location sharing.
@MainActor
final class TelemetryService: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var currentLocation: CLLocationCoordinate2D?
    @Published var locationEnabled = false
    @Published var peerLocations: [PeerLocation] = []
    @Published var telemetryData: DeviceTelemetry = .init()
    @Published var locationAuthStatus: CLAuthorizationStatus = .notDetermined

    // MARK: - Properties

    private let locationManager = CLLocationManager()
    private var updateTimer: Timer?

    // MARK: - Initialization

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50 // meters
        locationManager.allowsBackgroundLocationUpdates = false
    }

    // MARK: - Location Control

    func requestLocationPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func startLocationUpdates() {
        guard CLLocationManager.locationServicesEnabled() else { return }

        let status = locationManager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            requestLocationPermission()
            return
        }

        locationManager.startUpdatingLocation()
        locationEnabled = true
    }

    func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
        locationEnabled = false
        currentLocation = nil
    }

    // MARK: - Telemetry

    func collectTelemetry() -> DeviceTelemetry {
        var telemetry = DeviceTelemetry()
        telemetry.timestamp = Date()

        // Battery — enable monitoring only while reading, then disable to save power
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        telemetry.batteryLevel = device.batteryLevel >= 0 ? device.batteryLevel : nil
        telemetry.batteryCharging = device.batteryState == .charging || device.batteryState == .full
        device.isBatteryMonitoringEnabled = false

        // Location
        if let location = currentLocation {
            telemetry.latitude = location.latitude
            telemetry.longitude = location.longitude
        }

        self.telemetryData = telemetry
        return telemetry
    }

    // MARK: - Peer Location Management

    func updatePeerLocation(hash: Data, latitude: Double, longitude: Double, timestamp: Date = Date()) {
        let hexHash = hash.map { String(format: "%02x", $0) }.joined()

        if let idx = peerLocations.firstIndex(where: { $0.peerHash == hexHash }) {
            peerLocations[idx].latitude = latitude
            peerLocations[idx].longitude = longitude
            peerLocations[idx].lastUpdate = timestamp
        } else {
            peerLocations.append(PeerLocation(
                peerHash: hexHash,
                latitude: latitude,
                longitude: longitude,
                lastUpdate: timestamp
            ))
        }
    }

    func clearStalePeerLocations(olderThan interval: TimeInterval = 3600) {
        let cutoff = Date().addingTimeInterval(-interval)
        peerLocations.removeAll { $0.lastUpdate < cutoff }
    }

    // MARK: - Periodic Updates

    func startPeriodicTelemetry(interval: TimeInterval = 60) {
        stopPeriodicTelemetry()
        updateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = self?.collectTelemetry()
                self?.clearStalePeerLocations()
            }
        }
    }

    func stopPeriodicTelemetry() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
}

// MARK: - CLLocationManagerDelegate

extension TelemetryService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.currentLocation = location.coordinate
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.locationAuthStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse ||
               manager.authorizationStatus == .authorizedAlways {
                if self.locationEnabled {
                    manager.startUpdatingLocation()
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location errors are non-fatal; we just won't have a position
    }
}

// MARK: - Models

struct DeviceTelemetry {
    var timestamp: Date = Date()
    var batteryLevel: Float?
    var batteryCharging: Bool = false
    var latitude: Double?
    var longitude: Double?
}

struct PeerLocation: Identifiable {
    let id = UUID()
    let peerHash: String
    var latitude: Double
    var longitude: Double
    var lastUpdate: Date
    var displayName: String?

    var shortHash: String {
        String(peerHash.prefix(8)) + "…"
    }
}
