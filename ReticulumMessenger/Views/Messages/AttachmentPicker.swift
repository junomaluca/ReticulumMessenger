// SPDX-License-Identifier: MIT
// ReticulumMessenger — AttachmentPicker.swift
// Image, file, and audio attachment selection and preview.

import SwiftUI
import PhotosUI
import AVFoundation

// MARK: - Attachment Menu

struct AttachmentMenu: View {
    @Binding var showImagePicker: Bool
    @Binding var showFilePicker: Bool
    @Binding var isRecordingAudio: Bool

    var body: some View {
        Menu {
            Button {
                showImagePicker = true
            } label: {
                Label("Photo", systemImage: "photo")
            }

            Button {
                showFilePicker = true
            } label: {
                Label("File", systemImage: "doc")
            }

            Button {
                isRecordingAudio.toggle()
            } label: {
                Label("Voice Message", systemImage: "mic")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
        }
    }
}

// MARK: - Image Picker

struct ImagePickerView: UIViewControllerRepresentable {
    @Binding var selectedImage: UIImage?
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePickerView

        init(_ parent: ImagePickerView) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let result = results.first else { return }
            result.itemProvider.loadObject(ofClass: UIImage.self) { image, _ in
                DispatchQueue.main.async {
                    self.parent.selectedImage = image as? UIImage
                }
            }
        }
    }
}

// MARK: - File Picker

struct FilePickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FilePickerView

        init(_ parent: FilePickerView) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}

// MARK: - Audio Recorder

class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var recordedURL: URL?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default)
        try? session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice_\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return }
        self.recorder = recorder
        recorder.delegate = self
        recorder.record()

        isRecording = true
        recordingDuration = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.recordingDuration = self?.recorder?.currentTime ?? 0
        }
    }

    func stopRecording() {
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        recordedURL = recorder?.url
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if flag {
            recordedURL = recorder.url
        }
    }
}

// MARK: - Audio Recorder View

struct AudioRecorderView: View {
    @StateObject private var recorder = AudioRecorder()
    let onRecorded: (URL) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Text(formatDuration(recorder.recordingDuration))
                .font(.system(size: 48, weight: .light, design: .monospaced))

            HStack(spacing: 40) {
                Button("Cancel") {
                    recorder.stopRecording()
                    dismiss()
                }

                Button {
                    if recorder.isRecording {
                        recorder.stopRecording()
                        if let url = recorder.recordedURL {
                            onRecorded(url)
                        }
                        dismiss()
                    } else {
                        recorder.startRecording()
                    }
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(recorder.isRecording ? .red : .accentColor)
                }
            }
        }
        .padding()
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int(duration * 10) % 10
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }
}

// MARK: - Image Message Bubble

struct ImageMessageView: View {
    let imageData: Data

    var body: some View {
        if let uiImage = UIImage(data: imageData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
