// SPDX-License-Identifier: MIT
// ReticulumMessenger — Data+Hex.swift
// Shared hex-string ↔ Data conversion.

import Foundation

extension Data {
    /// Create `Data` from a hex-encoded string (e.g. "a1b2c3").
    /// Returns `nil` if the string contains non-hex characters or has odd length.
    init?(hexString hex: String) {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                  nextIndex != index,
                  let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    /// Hex-encoded string representation of the data.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
