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
    @State private var shareItem: ShareableAttachment?

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

                    if !message.allAttachments.isEmpty {
                        ForEach(Array(message.allAttachments.enumerated()), id: \.offset) { _, att in
                            attachmentView(att)
                        }
                        if !message.content.isEmpty,
                           message.content != message.attachment?.filename,
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

                        if let att = message.attachment {
                            Button {
                                shareAttachment(att)
                            } label: {
                                Label("Save / Share", systemImage: "square.and.arrow.up")
                            }
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
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.tempURL])
        }
    }

    private var isPlayableAudio: Bool {
        guard let att = message.attachment, att.mimeType.hasPrefix("audio/") else { return false }
        let mime = att.mimeType.lowercased()
        return mime.contains("m4a") || mime.contains("mp4") || mime.contains("mpeg")
            || mime.contains("wav") || mime.contains("aiff") || mime.contains("caf")
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
                .onTapGesture { shareAttachment(attachment) }
        } else if attachment.mimeType.hasPrefix("image/") {
            // Image MIME but data can't be decoded — show as file
            HStack(spacing: 8) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title3)
                    .foregroundColor(message.isIncoming ? .accentColor : .white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .font(.caption.bold())
                        .foregroundColor(message.isIncoming ? .primary : .white)
                    Text("\(formatFileSize(attachment.data.count)) — unsupported format")
                        .font(.caption2)
                        .foregroundColor(message.isIncoming ? .secondary : .white.opacity(0.7))
                }
            }
            .onTapGesture { shareAttachment(attachment) }
        } else if attachment.mimeType.hasPrefix("audio/") {
            let playable = canPlayAudio(attachment.mimeType)
            HStack(spacing: 10) {
                Button {
                    if playable {
                        toggleAudioPlayback(attachment.data)
                    } else {
                        shareAttachment(attachment)
                    }
                } label: {
                    Image(systemName: playable
                          ? (isPlayingAudio ? "stop.circle.fill" : "play.circle.fill")
                          : "square.and.arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(message.isIncoming ? .accentColor : .white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(audioLabel(attachment))
                        .font(.caption.bold())
                        .foregroundColor(message.isIncoming ? .primary : .white)
                    Text(formatFileSize(attachment.data.count))
                        .font(.caption2)
                        .foregroundColor(message.isIncoming ? .secondary : .white.opacity(0.7))
                }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: fileIcon(for: attachment.mimeType))
                    .font(.title3)
                    .foregroundColor(message.isIncoming ? .accentColor : .white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .font(.caption.bold())
                        .foregroundColor(message.isIncoming ? .primary : .white)
                        .lineLimit(2)
                    Text(formatFileSize(attachment.data.count))
                        .font(.caption2)
                        .foregroundColor(message.isIncoming ? .secondary : .white.opacity(0.7))
                }
            }
            .onTapGesture { shareAttachment(attachment) }
        }
    }

    private func canPlayAudio(_ mime: String) -> Bool {
        let m = mime.lowercased()
        return m.contains("m4a") || m.contains("mp4") || m.contains("mpeg")
            || m.contains("wav") || m.contains("aiff") || m.contains("caf")
    }

    private func audioLabel(_ att: ChatAttachment) -> String {
        let m = att.mimeType.lowercased()
        if m.contains("opus") { return "Opus Audio" }
        if m.contains("codec2") { return "Codec2 Audio" }
        return "Voice Message"
    }

    private func fileIcon(for mime: String) -> String {
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.contains("json") || mime.contains("text") || mime.contains("csv") { return "doc.text" }
        if mime.contains("zip") || mime.contains("tar") || mime.contains("gz") { return "doc.zipper" }
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        return "doc.fill"
    }

    private func shareAttachment(_ att: ChatAttachment) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(att.filename)
        try? att.data.write(to: tmp)
        shareItem = ShareableAttachment(tempURL: tmp)
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

// MARK: - Share Sheet

struct ShareableAttachment: Identifiable {
    let id = UUID()
    let tempURL: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
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
