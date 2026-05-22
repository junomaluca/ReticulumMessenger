// SPDX-License-Identifier: MIT
// ReticulumMessenger — MessageBubble.swift

import SwiftUI
import AVFoundation

struct MessageBubble: View {
    let message: ChatMessage
    var onReaction: ((String) -> Void)?
    var onForward: (() -> Void)?
    var onCopy: (() -> Void)?
    var disappearingDuration: DisappearingDuration = .off

    @State private var showReactionPicker = false
    @State private var isPlayingAudio = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var audioDelegate: AudioPlaybackDelegate?

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

                    if let attachment = message.attachment {
                        attachmentView(attachment)
                        // Also show body text if it carries something extra
                        // beyond the attachment's own filename (e.g. captions
                        // from peers that send image + caption together).
                        if !message.content.isEmpty,
                           message.content != attachment.filename,
                           message.content != "Attachment" {
                            Text(message.content)
                                .font(.body)
                                .foregroundColor(message.isIncoming ? .primary : .white)
                        }
                    } else {
                        Text(message.content)
                            .font(.body)
                            .foregroundColor(message.isIncoming ? .primary : .white)
                    }

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

    @ViewBuilder
    private func attachmentView(_ attachment: ChatAttachment) -> some View {
        if attachment.mimeType.hasPrefix("image/"),
           let uiImage = UIImage(data: attachment.data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220, maxHeight: 220)
                .cornerRadius(8)
        } else if attachment.mimeType.hasPrefix("audio/") {
            HStack(spacing: 10) {
                Button {
                    toggleAudioPlayback(attachment.data)
                } label: {
                    Image(systemName: isPlayingAudio ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(message.isIncoming ? .accentColor : .white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice Message")
                        .font(.caption.bold())
                        .foregroundColor(message.isIncoming ? .primary : .white)
                    Text(formatFileSize(attachment.data.count))
                        .font(.caption2)
                        .foregroundColor(message.isIncoming ? .secondary : .white.opacity(0.7))
                }
            }
        } else {
            // Generic file attachment
            HStack(spacing: 8) {
                Image(systemName: "doc.fill")
                    .font(.title3)
                    .foregroundColor(message.isIncoming ? .accentColor : .white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .font(.caption.bold())
                        .foregroundColor(message.isIncoming ? .primary : .white)
                    Text(formatFileSize(attachment.data.count))
                        .font(.caption2)
                        .foregroundColor(message.isIncoming ? .secondary : .white.opacity(0.7))
                }
            }
        }
    }

    private func toggleAudioPlayback(_ data: Data) {
        if isPlayingAudio {
            audioPlayer?.stop()
            audioPlayer = nil
            audioDelegate = nil
            isPlayingAudio = false
        } else {
            do {
                let player = try AVAudioPlayer(data: data)
                // Hold a strong ref to the delegate; AVAudioPlayer keeps a
                // weak one and would never call audioPlayerDidFinishPlaying
                // otherwise, leaving the icon stuck on "stop".
                let delegate = AudioPlaybackDelegate {
                    Task { @MainActor in
                        isPlayingAudio = false
                        audioPlayer = nil
                        audioDelegate = nil
                    }
                }
                player.delegate = delegate
                player.play()
                audioPlayer = player
                audioDelegate = delegate
                isPlayingAudio = true
            } catch {
                isPlayingAudio = false
            }
        }
    }

    private func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
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

/// Bridges AVAudioPlayer's Obj-C-style delegate callbacks back into the
/// SwiftUI bubble so we can flip the icon from stop back to play when
/// playback finishes naturally (vs. the user tapping stop). Lives outside
/// the View so its lifetime isn't tied to a body re-render.
final class AudioPlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish()
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
