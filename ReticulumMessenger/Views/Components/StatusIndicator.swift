// SPDX-License-Identifier: MIT
// ReticulumMessenger — StatusIndicator.swift

import SwiftUI

/// Compact network status indicator for the navigation bar.
struct StatusIndicator: View {
    let status: NetworkStatus
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
                .overlay {
                    if status == .connecting {
                        Circle()
                            .stroke(status.color, lineWidth: 1.5)
                            .scaleEffect(isPulsing ? 2.0 : 1.0)
                            .opacity(isPulsing ? 0 : 0.8)
                    }
                }
                .onChange(of: status) { _, newStatus in
                    if newStatus == .connecting {
                        isPulsing = false
                        withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                            isPulsing = true
                        }
                    } else {
                        isPulsing = false
                    }
                }
                .onAppear {
                    if status == .connecting {
                        withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                            isPulsing = true
                        }
                    }
                }

            Text(status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
