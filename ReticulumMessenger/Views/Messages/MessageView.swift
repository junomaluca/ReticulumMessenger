// SPDX-License-Identifier: MIT
// ReticulumMessenger — MessageView.swift

import SwiftUI
import PhotosUI

struct MessageView: View {
    @EnvironmentObject var appState: AppState
    let conversation: Conversation

    @State private var messageText = ""
    @State private var isSending = false
    @FocusState private var isInputFocused: Bool

    // Attachment state
    @State private var showImagePicker = false
    @State private var showFilePicker = false
    @State private var isRecordingAudio = false
    @State private var selectedImage: UIImage?
    @State private var pendingAttachmentData: Data?
    @State private var pendingAttachmentMime: String?
    @State private var pendingAttachmentName: String?

    // Forward state
    @State private var forwardingMessage: ChatMessage?
    @State private var showForwardSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Disappearing messages banner
            if currentConversation.disappearingDuration != .off {
                disappearingBanner
            }

            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(currentMessages) { message in
                            MessageBubble(
                                message: message,
                                onReaction: { emoji in
                                    toggleReaction(emoji, on: message.id)
                                },
                                onForward: {
                                    forwardingMessage = message
                                    showForwardSheet = true
                                },
                                onCopy: nil,
                                disappearingDuration: currentConversation.disappearingDuration
                            )
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .onChange(of: currentMessages.count) { _, _ in
                    if let last = currentMessages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let last = currentMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            // Pending attachment preview
            if let imageData = pendingAttachmentData,
               let uiImage = UIImage(data: imageData) {
                attachmentPreview(image: uiImage)
            } else if pendingAttachmentName != nil {
                fileAttachmentPreview
            }

            Divider()

            // Input bar with attachment menu
            HStack(alignment: .bottom, spacing: 8) {
                AttachmentMenu(
                    showImagePicker: $showImagePicker,
                    showFilePicker: $showFilePicker,
                    isRecordingAudio: $isRecordingAudio
                )

                TextField("Message", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 20))

                Button(action: sendMessage) {
                    Group {
                        if isSending {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.body.bold())
                        }
                    }
                    .frame(width: 20, height: 20)
                    .padding(8)
                    .foregroundStyle(.white)
                    .background(canSend ? Color.accentColor : Color.gray, in: Circle())
                }
                .disabled(!canSend)
                .animation(.easeInOut(duration: 0.15), value: canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(currentConversation.resolvedName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    if currentConversation.isGroup {
                        GroupDetailView(conversation: currentConversation)
                    } else {
                        PeerDetailView(conversation: currentConversation)
                    }
                } label: {
                    if currentConversation.isGroup {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 14))
                    } else {
                        AvatarView(hash: currentConversation.peerHash, size: 28)
                    }
                }
            }
        }
        .onAppear {
            markAsRead()
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePickerView(selectedImage: $selectedImage)
        }
        .sheet(isPresented: $showFilePicker) {
            FilePickerView { url in
                handlePickedFile(url)
            }
        }
        .sheet(isPresented: $isRecordingAudio) {
            AudioRecorderView { url in
                handleRecordedAudio(url)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showForwardSheet) {
            ForwardMessageSheet(message: forwardingMessage) { targetConversation in
                forwardMessage(forwardingMessage, to: targetConversation)
            }
        }
        .onChange(of: currentMessages.count) { _, _ in
            markAsRead()
        }
        .onChange(of: selectedImage) { _, newImage in
            if let image = newImage {
                let resized = Self.downscaleForLXMF(image)
                pendingAttachmentData = resized
                pendingAttachmentMime = "image/jpeg"
                pendingAttachmentName = "photo.jpg"
            }
        }
    }

    // MARK: - Computed

    private var currentConversation: Conversation {
        appState.conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }

    private var currentMessages: [ChatMessage] {
        currentConversation.messages.filter { !$0.isExpired }
    }

    private var canSend: Bool {
        let hasText = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachment = pendingAttachmentData != nil
        return (hasText || hasAttachment) && !isSending
    }

    // MARK: - Subviews

    private var disappearingBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.caption2)
            Text("Disappearing messages: \(currentConversation.disappearingDuration.label)")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
    }

    private func attachmentPreview(image: UIImage) -> some View {
        HStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Spacer()

            Button {
                clearPendingAttachment()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var fileAttachmentPreview: some View {
        HStack {
            Image(systemName: "doc.fill")
                .foregroundStyle(Color.accentColor)
            Text(pendingAttachmentName ?? "File")
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Button {
                clearPendingAttachment()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Actions

    private func sendMessage() {
        let content = messageText.trimmingCharacters(in: .whitespacesAndNewlines)

        if let attachmentData = pendingAttachmentData,
           let mime = pendingAttachmentMime {
            let caption = content
            messageText = ""
            isSending = true
            let name = pendingAttachmentName
            clearPendingAttachment()

            Task {
                do {
                    try await appState.sendAttachment(
                        data: attachmentData,
                        mimeType: mime,
                        filename: name,
                        to: conversation.peerHash,
                        body: caption
                    )
                } catch {
                    markLastOutgoingAsFailed()
                }
                isSending = false
            }
        } else if !content.isEmpty {
            messageText = ""
            isSending = true

            Task {
                do {
                    if conversation.isGroup {
                        try await appState.sendGroupMessage(content: content, groupConversation: currentConversation)
                    } else {
                        try await appState.sendMessage(content: content, to: conversation.peerHash)
                    }
                } catch {
                    markLastOutgoingAsFailed()
                }
                isSending = false
            }
        }
    }

    private func toggleReaction(_ emoji: String, on messageId: UUID) {
        guard let convIdx = appState.conversations.firstIndex(where: { $0.id == conversation.id }),
              let msgIdx = appState.conversations[convIdx].messages.firstIndex(where: { $0.id == messageId }) else { return }

        appState.conversations[convIdx].messages[msgIdx].toggleReaction(emoji, isLocal: true)
        appState.storageService?.saveConversations(appState.conversations)
    }

    private func forwardMessage(_ message: ChatMessage?, to target: Conversation) {
        guard let message else { return }
        Task {
            if let att = message.attachment {
                try? await appState.sendAttachment(
                    data: att.data,
                    mimeType: att.mimeType,
                    filename: att.filename,
                    to: target.peerHash,
                    body: message.content
                )
            } else {
                try? await appState.sendMessage(content: message.content, to: target.peerHash)
            }
        }
    }

    private func handlePickedFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        if let data = try? Data(contentsOf: url) {
            pendingAttachmentData = data
            pendingAttachmentMime = mimeType(for: url)
            pendingAttachmentName = url.lastPathComponent
        }
    }

    private func handleRecordedAudio(_ url: URL) {
        if let data = try? Data(contentsOf: url) {
            pendingAttachmentData = data
            pendingAttachmentMime = "audio/m4a"
            pendingAttachmentName = url.lastPathComponent
        }
    }

    private func clearPendingAttachment() {
        pendingAttachmentData = nil
        pendingAttachmentMime = nil
        pendingAttachmentName = nil
        selectedImage = nil
    }

    private func markAsRead() {
        guard let idx = appState.conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        for i in appState.conversations[idx].messages.indices {
            if appState.conversations[idx].messages[i].isIncoming {
                appState.conversations[idx].messages[i].isRead = true
            }
        }
        appState.storageService?.saveConversations(appState.conversations)
        NotificationService.shared.clearNotifications(for: conversation.peerHexHash)
        let totalUnread = appState.conversations.reduce(0) { $0 + $1.unreadCount }
        NotificationService.shared.updateBadgeCount(totalUnread)
    }

    private func markLastOutgoingAsFailed() {
        guard let idx = appState.conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        if let lastIdx = appState.conversations[idx].messages.indices.last,
           !appState.conversations[idx].messages[lastIdx].isIncoming,
           appState.conversations[idx].messages[lastIdx].state == .pending {
            appState.conversations[idx].messages[lastIdx].state = .failed
        }
    }

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "m4a": return "audio/m4a"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }

    /// Downscale a UIImage so the JPEG output stays under ~250 KB — large
    /// enough for a sharp preview, small enough for reliable LXMF delivery
    /// over Reticulum (the protocol uses link-based Resource transfer for
    /// payloads above ~500 B, but very large transfers can time out on
    /// high-latency mesh paths).
    private static func downscaleForLXMF(_ image: UIImage) -> Data {
        let maxDim: CGFloat = 1024
        var img = image
        if max(image.size.width, image.size.height) > maxDim {
            let scale = maxDim / max(image.size.width, image.size.height)
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            img = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        }
        // Try progressively lower quality until we're under the target.
        for q: CGFloat in [0.6, 0.4, 0.25, 0.15] {
            if let data = img.jpegData(compressionQuality: q), data.count <= 250_000 {
                return data
            }
        }
        return img.jpegData(compressionQuality: 0.1) ?? Data()
    }
}

// MARK: - Forward Message Sheet

struct ForwardMessageSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage?
    let onForward: (Conversation) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let message {
                    Section {
                        HStack {
                            Image(systemName: "arrowshape.turn.up.right.fill")
                                .foregroundStyle(Color.accentColor)
                            Text(message.content)
                                .lineLimit(2)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Forward to") {
                    ForEach(appState.conversations) { conversation in
                        Button {
                            onForward(conversation)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(hash: conversation.peerHash, size: 36)
                                Text(conversation.resolvedName)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Forward Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Peer Detail

struct PeerDetailView: View {
    @EnvironmentObject var appState: AppState
    let conversation: Conversation

    @State private var disappearingDuration: DisappearingDuration = .off
    @State private var editedName: String = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        AvatarView(hash: conversation.peerHash, size: 80)
                        TextField(conversation.shortHash, text: $editedName)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.plain)
                            .submitLabel(.done)
                            .focused($nameFieldFocused)
                            .onSubmit { commitName() }
                        Text(conversation.peerHexHash)
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } footer: {
                Text("Tap the name to rename this peer locally.")
            }

            Section("Details") {
                LabeledContent("Destination Hash") {
                    Text(conversation.shortHash)
                        .monospaced()
                }
                LabeledContent("Messages") {
                    Text("\(conversation.messages.count)")
                }
                if let lastMsg = conversation.lastMessage {
                    LabeledContent("Last Activity") {
                        Text(lastMsg.timestamp, style: .relative)
                    }
                }
            }

            Section {
                Picker("Auto-delete after", selection: $disappearingDuration) {
                    ForEach(DisappearingDuration.allCases, id: \.self) { duration in
                        Label(duration.label, systemImage: duration.icon)
                            .tag(duration)
                    }
                }
                .onChange(of: disappearingDuration) { _, newValue in
                    appState.setDisappearingDuration(newValue, for: conversation.id)
                }
            } header: {
                Text("Disappearing Messages")
            } footer: {
                Text("When enabled, messages in this conversation will automatically disappear after the selected time period.")
            }

            Section {
                Button {
                    UIPasteboard.general.string = conversation.peerHexHash
                } label: {
                    Label("Copy Address", systemImage: "doc.on.doc")
                }
            }
        }
        .navigationTitle("Peer Info")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let conv = appState.conversations.first(where: { $0.id == conversation.id }) {
                disappearingDuration = conv.disappearingDuration
                editedName = conv.displayName ?? ""
            }
        }
        .onChange(of: nameFieldFocused) { _, focused in
            if !focused { commitName() }
        }
        .onDisappear { commitName() }
    }

    private func commitName() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName: String? = trimmed.isEmpty ? nil : trimmed
        let current = appState.conversations.first(where: { $0.id == conversation.id })?.displayName
        guard newName != current else { return }
        appState.setDisplayName(newName, for: conversation.id)
    }
}
