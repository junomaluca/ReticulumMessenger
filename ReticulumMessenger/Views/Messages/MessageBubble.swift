// SPDX-License-Identifier: MIT
// ReticulumMessenger — MessageBubble.swift

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    var onReaction: ((String) -> Void)?
    var onForward: (() -> Void)?
    var onCopy: (() -> Void)?
    var disappearingDuration: DisappearingDuration = .off

    @State private var showReactionPicker = false

    private let reactionEmojis = ["👍", "❤️", "😂", "😮", "🔥", "🙏"]

    var body: some View {
        HStack {
            if !message.isIncoming { Spacer(minLength: 60) }

            VStack(alignment: message.isIncoming ? .leading : .trailing, spacing: 4) {
                // Reactions display
                if !message.reactions.isEmpty {
                    reactionBar
                }

                // Message content
                VStack(alignment: message.isIncoming ? .leading : .trailing, spacing: 4) {
                    if message.isIncoming, let sender = message.senderName {
                        Text(sender)
                            .font(.caption.bold())
                            .foregroundColor(.accentColor)
                    }

                    Text(message.content)
                        .font(.body)
                        .foregroundColor(message.isIncoming ? .primary : .white)

                    HStack(spacing: 4) {
                        if disappearingDuration != .off {
                            Image(systemName: "timer")
                                .font(.system(size: 8))
                        }

                        if let expiresAt = message.expiresAt {
                            Text(expiresAt, style: .relative)
                                .font(.system(size: 9))
                        } else {
                            Text(message.timestamp, style: .time)
                                .font(.caption2)
                        }

                        if !message.isIncoming {
                            Image(systemName: stateIcon)
                                .font(.caption2)
                        }
                    }
                    .foregroundColor(
                        message.isIncoming ? .secondary : .white.opacity(0.7)
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(bubbleBackground, in: BubbleShape(isIncoming: message.isIncoming))
                .contextMenu {
                    // Reactions row
                    Section {
                        ForEach(reactionEmojis, id: \.self) { emoji in
                            Button {
                                onReaction?(emoji)
                            } label: {
                                Text(emoji)
                            }
                        }
                    }

                    // Actions
                    Section {
                        Button {
                            UIPasteboard.general.string = message.content
                            onCopy?()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }

                        Button {
                            onForward?()
                        } label: {
                            Label("Forward", systemImage: "arrowshape.turn.up.right")
                        }
                    }
                }
            }

            if message.isIncoming { Spacer(minLength: 60) }
        }
        .padding(.vertical, 2)
    }

    private var reactionBar: some View {
        HStack(spacing: 2) {
            ForEach(groupedReactions, id: \.emoji) { group in
                HStack(spacing: 2) {
                    Text(group.emoji)
                        .font(.system(size: 14))
                    if group.count > 1 {
                        Text("\(group.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    group.hasLocal ? Color.accentColor.opacity(0.15) : Color(.systemGray5),
                    in: Capsule()
                )
                .onTapGesture {
                    onReaction?(group.emoji)
                }
            }
        }
    }

    private var groupedReactions: [ReactionGroup] {
        var groups: [String: ReactionGroup] = [:]
        for reaction in message.reactions {
            if var group = groups[reaction.emoji] {
                group.count += 1
                if reaction.isLocal { group.hasLocal = true }
                groups[reaction.emoji] = group
            } else {
                groups[reaction.emoji] = ReactionGroup(
                    emoji: reaction.emoji,
                    count: 1,
                    hasLocal: reaction.isLocal
                )
            }
        }
        return Array(groups.values).sorted { $0.emoji < $1.emoji }
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

private struct ReactionGroup {
    let emoji: String
    var count: Int
    var hasLocal: Bool
}

// MARK: - Bubble Shape

struct BubbleShape: Shape {
    let isIncoming: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let tailSize: CGFloat = 6

        var path = Path()

        if isIncoming {
            path.addRoundedRect(
                in: CGRect(x: tailSize, y: 0, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            path.move(to: CGPoint(x: tailSize, y: rect.height - radius))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.addLine(to: CGPoint(x: tailSize + radius, y: rect.height))
        } else {
            path.addRoundedRect(
                in: CGRect(x: 0, y: 0, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            path.move(to: CGPoint(x: rect.width - tailSize, y: rect.height - radius))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width - tailSize - radius, y: rect.height))
        }

        return path
    }
}
