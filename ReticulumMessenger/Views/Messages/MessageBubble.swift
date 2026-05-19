// SPDX-License-Identifier: MIT
// ReticulumMessenger — MessageBubble.swift

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if !message.isIncoming { Spacer(minLength: 60) }

            VStack(alignment: message.isIncoming ? .leading : .trailing, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .foregroundStyle(message.isIncoming ? .primary : .white)

                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)

                    if !message.isIncoming {
                        Image(systemName: stateIcon)
                            .font(.caption2)
                    }
                }
                .foregroundStyle(
                    message.isIncoming ? .secondary : .white.opacity(0.7)
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(bubbleBackground, in: BubbleShape(isIncoming: message.isIncoming))

            if message.isIncoming { Spacer(minLength: 60) }
        }
        .padding(.vertical, 2)
    }

    private var bubbleBackground: Color {
        if message.isIncoming {
            return Color(.systemGray6)
        }
        return message.state == .failed ? .red : .accentColor
    }

    private var stateIcon: String {
        switch message.state {
        case .pending: return "clock"
        case .sent: return "checkmark"
        case .delivered: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

// MARK: - Bubble Shape

struct BubbleShape: Shape {
    let isIncoming: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let tailSize: CGFloat = 6

        var path = Path()

        if isIncoming {
            // Rounded rect with tail on bottom-left
            path.addRoundedRect(
                in: CGRect(x: tailSize, y: 0, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            // Small tail
            path.move(to: CGPoint(x: tailSize, y: rect.height - radius))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.addLine(to: CGPoint(x: tailSize + radius, y: rect.height))
        } else {
            // Rounded rect with tail on bottom-right
            path.addRoundedRect(
                in: CGRect(x: 0, y: 0, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            // Small tail
            path.move(to: CGPoint(x: rect.width - tailSize, y: rect.height - radius))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width - tailSize - radius, y: rect.height))
        }

        return path
    }
}
