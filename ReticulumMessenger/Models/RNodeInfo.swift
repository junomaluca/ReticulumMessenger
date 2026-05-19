// SPDX-License-Identifier: MIT
// ReticulumMessenger — RNodeInfo.swift

import Foundation
import ReticulumKit

/// UI-friendly representation of a connected RNode device.
struct RNodeInfo {
    let name: String
    let deviceId: UUID
    var config: RNodeConfig
    var firmwareVersion: String?
    var lastRSSI: Int?
    var lastSNR: Float?
    var batteryLevel: UInt8?
    var radioOnline: Bool
}
