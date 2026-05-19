// SPDX-License-Identifier: MIT
// ReticulumMessenger — QRCodeView.swift
// QR code generation and scanning for identity sharing and paper messages.

import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0

    var body: some View {
        VStack {
            Picker("Mode", selection: $selectedTab) {
                Text("My Identity").tag(0)
                Text("Scan").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            TabView(selection: $selectedTab) {
                myIdentityQR.tag(0)
                scannerView.tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle("QR Code")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - My Identity QR

    private var myIdentityQR: some View {
        VStack(spacing: 20) {
            Spacer()

            if let image = generateQRCode(from: appState.deliveryHash) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 250, height: 250)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 4)
            }

            Text("LXMF Address")
                .font(.headline)

            Text(appState.deliveryHash)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("Others can scan this code to message you")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button {
                UIPasteboard.general.string = appState.deliveryHash
            } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding()
    }

    // MARK: - Scanner

    private var scannerView: some View {
        QRScannerView { scannedString in
            handleScannedCode(scannedString)
        }
    }

    // MARK: - Helpers

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: transform)

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func handleScannedCode(_ code: String) {
        // Handle lxm:// URI scheme for paper messages
        if code.hasPrefix("lxm://") {
            handlePaperMessage(code)
            return
        }

        // Treat as destination hash
        let cleaned = code.replacingOccurrences(of: " ", with: "").lowercased()
        if cleaned.count == 32, cleaned.allSatisfy({ $0.isHexDigit }) {
            if let hashData = Data(hexString: cleaned) {
                appState.createConversation(with: hashData, name: nil)
                dismiss()
            }
        }
    }

    private func handlePaperMessage(_ uri: String) {
        // Parse lxm:// URI and create conversation with embedded message
        // Format: lxm://destination_hash/encoded_message
        let path = uri.replacingOccurrences(of: "lxm://", with: "")
        let parts = path.split(separator: "/", maxSplits: 1)
        guard let destHex = parts.first, destHex.count == 32 else { return }

        if let hashData = Data(hexString: String(destHex)) {
            appState.createConversation(with: hashData, name: nil)
            dismiss()
        }
    }

}

// MARK: - QR Scanner

struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private var captureSession: AVCaptureSession?

    override func viewDidLoad() {
        super.viewDidLoad()

        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showPlaceholder()
            return
        }

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        self.captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let string = object.stringValue else { return }
        captureSession?.stopRunning()
        onScan?(string)
    }

    private func showPlaceholder() {
        let label = UILabel()
        label.text = NSLocalizedString("Camera not available\nEnter address manually", comment: "")
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
