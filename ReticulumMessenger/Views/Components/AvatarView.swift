// SPDX-License-Identifier: MIT
// ReticulumMessenger — AvatarView.swift

import SwiftUI

/// Generates a deterministic avatar from a hash.
/// Uses the hash bytes to determine colors and a geometric pattern,
/// producing a unique visual identifier for each peer.
struct AvatarView: View {
    let hash: Data
    let size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let cellSize = canvasSize.width / 5

            // Background
            context.fill(
                Path(CGRect(origin: .zero, size: canvasSize)),
                with: .color(backgroundColor)
            )

            // Draw symmetric pattern
            for row in 0..<5 {
                for col in 0..<3 {
                    let byteIndex = (row * 3 + col) % max(hash.count, 1)
                    let byte = hash.isEmpty ? UInt8(0) : hash[byteIndex]

                    if byte % 2 == 0 {
                        let rect = CGRect(
                            x: CGFloat(col) * cellSize,
                            y: CGFloat(row) * cellSize,
                            width: cellSize,
                            height: cellSize
                        )
                        context.fill(Path(rect), with: .color(foregroundColor))

                        // Mirror for columns 3 and 4
                        if col < 2 {
                            let mirrorRect = CGRect(
                                x: CGFloat(4 - col) * cellSize,
                                y: CGFloat(row) * cellSize,
                                width: cellSize,
                                height: cellSize
                            )
                            context.fill(Path(mirrorRect), with: .color(foregroundColor))
                        }
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }

    private var backgroundColor: Color {
        guard hash.count >= 3 else { return .gray.opacity(0.2) }
        return Color(
            hue: Double(hash[0]) / 255.0,
            saturation: 0.15,
            brightness: 0.95
        )
    }

    private var foregroundColor: Color {
        guard hash.count >= 3 else { return .accentColor }
        return Color(
            hue: Double(hash[0]) / 255.0,
            saturation: Double(hash[1]) / 255.0 * 0.5 + 0.3,
            brightness: Double(hash[2]) / 255.0 * 0.3 + 0.3
        )
    }
}
