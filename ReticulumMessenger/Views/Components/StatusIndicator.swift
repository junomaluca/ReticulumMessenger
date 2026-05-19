// SPDX-License-Identifier: MIT
// ReticulumMessenger — StatusIndicator.swift

import SwiftUI

/// Compact network status indicator for the navigation bar.
struct StatusIndicator: View {
    let status: NetworkStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
                .overlay {
                    if status == .connecting {
                        Circle()
                            .stroke(status.color, lineWidth: 1.5)
                            .scaleEffect(1.8)
                            .opacity(0)
                            .animation(
                                .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                                value: UUID()
                            )
                    }
                }

            Text(status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
