import SwiftUI
import AVFoundation
import Vision

struct QRKeyScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scanState: ScanState = .requestingPermission
    @State private var availableCameras: [AVCaptureDevice] = []
    @State private var selectedCameraID: String?

    private enum ScanState {
        case requestingPermission
        case noPermission
        case noCamera
        case scanning
        case confirming(String)
        case installing
        case success
        case error(String)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan iOS Device SSH Key")
                .font(.headline)

            switch scanState {
            case .requestingPermission:
                ProgressView("Requesting camera access...")
                    .frame(width: 320, height: 240)

            case .noPermission:
                VStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Camera access is required to scan QR codes.")
                        .font(.body.weight(.medium))
                    Text("Grant access in System Settings > Privacy & Security > Camera.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                }

            case .noCamera:
                VStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No camera found.")
                        .font(.body.weight(.medium))
                    Text("Connect a camera to scan QR codes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .scanning:
                CameraPreviewView(
                    cameraID: selectedCameraID,
                    onQRCodeDetected: handleQRCode
                )
                .frame(width: 320, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.secondary.opacity(0.3), lineWidth: 1)
                )

                if availableCameras.count > 1 {
                    Picker("Camera", selection: cameraBinding) {
                        ForEach(availableCameras, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280)
                }

                Text("Point your camera at the QR code displayed on your iOS device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

            case .confirming(let key):
                let keyParts = key.components(separatedBy: " ")
                let keyType = keyParts.first ?? "unknown"
                let keyPreview = keyParts.count > 1
                    ? String(keyParts[1].prefix(12)) + "..." + String(keyParts[1].suffix(8))
                    : key.prefix(20) + "..."

                VStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.blue)

                    Text("Add this SSH key to authorized_keys?")
                        .font(.body.weight(.medium))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Type: \(keyType)")
                            .font(.caption.monospaced())
                        Text("Key: \(keyPreview)")
                            .font(.caption.monospaced())
                        if keyParts.count > 2 {
                            Text("Comment: \(keyParts[2...].joined(separator: " "))")
                                .font(.caption.monospaced())
                        }
                    }
                    .padding(8)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                HStack {
                    Button("Cancel") {
                        scanState = .scanning
                    }
                    Spacer()
                    Button("Add Key") {
                        installKey(key)
                    }
                    .keyboardShortcut(.defaultAction)
                }

            case .installing:
                ProgressView("Adding key...")

            case .success:
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    Text("SSH key added successfully.")
                        .font(.body.weight(.medium))
                    Text("The iOS device can now connect to this Mac via SSH.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)

            case .error(let message):
                VStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text("Failed to add SSH key")
                        .font(.body.weight(.medium))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Try Again") {
                        scanState = .scanning
                    }
                    Spacer()
                    Button("Close") { dismiss() }
                }
            }

            if case .scanning = scanState {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            } else if case .noPermission = scanState {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            } else if case .noCamera = scanState {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 380, height: 420)
        .task { await requestCameraAccess() }
    }

    private var cameraBinding: Binding<String> {
        Binding(
            get: { selectedCameraID ?? availableCameras.first?.uniqueID ?? "" },
            set: { newID in
                selectedCameraID = newID
                // Force re-creation of camera preview by toggling state
                scanState = .requestingPermission
                Task { @MainActor in
                    scanState = .scanning
                }
            }
        )
    }

    private func requestCameraAccess() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            setupCameras()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                setupCameras()
            } else {
                scanState = .noPermission
            }
        case .denied, .restricted:
            scanState = .noPermission
        @unknown default:
            scanState = .noPermission
        }
    }

    private func setupCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        availableCameras = discovery.devices

        if availableCameras.isEmpty {
            scanState = .noCamera
        } else {
            selectedCameraID = availableCameras.first?.uniqueID
            scanState = .scanning
        }
    }

    private func handleQRCode(_ code: String) {
        guard case .scanning = scanState else { return }

        guard let data = code.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              json["type"] == "agenthub-ssh-key",
              let publicKey = json["publicKey"]
        else {
            return
        }

        guard isValidSSHPublicKey(publicKey) else {
            scanState = .error("Invalid SSH key format.")
            return
        }

        scanState = .confirming(publicKey)
    }

    private func installKey(_ key: String) {
        scanState = .installing

        do {
            try SSHKeyInstaller.addToAuthorizedKeys(key)
            scanState = .success
        } catch SSHKeyInstaller.InstallError.duplicate {
            scanState = .error("This key is already in authorized_keys.")
        } catch {
            scanState = .error(error.localizedDescription)
        }
    }

    private func isValidSSHPublicKey(_ key: String) -> Bool {
        let validPrefixes = [
            "ssh-ed25519 ",
            "ssh-rsa ",
            "ecdsa-sha2-nistp256 ",
            "ecdsa-sha2-nistp384 ",
            "ecdsa-sha2-nistp521 ",
            "ssh-dss ",
        ]
        return validPrefixes.contains(where: { key.hasPrefix($0) })
    }
}

// MARK: - SSH Key Installer

private let agenthubKeyMarker = "# Added by AgentHub"

struct AgentHubSSHKey: Identifiable {
    let id: String // key type + key data
    let fullLine: String
    let keyType: String
    let keyData: String
    let comment: String
    let addedDate: String?
}

enum SSHKeyInstaller {
    enum InstallError: LocalizedError {
        case duplicate
        case permissionDenied(String)

        var errorDescription: String? {
            switch self {
            case .duplicate:
                return "Key already exists in authorized_keys."
            case .permissionDenied(let detail):
                return "Permission error: \(detail)"
            }
        }
    }

    private static var authKeysURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/authorized_keys")
    }

    private static var sshDirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
    }

    static func addToAuthorizedKeys(_ publicKey: String) throws {
        let fm = FileManager.default

        // Ensure ~/.ssh exists with 700 permissions
        if !fm.fileExists(atPath: sshDirURL.path) {
            try fm.createDirectory(at: sshDirURL, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDirURL.path)
        } else {
            let attrs = try fm.attributesOfItem(atPath: sshDirURL.path)
            if let perms = attrs[.posixPermissions] as? Int, perms & 0o077 != 0 {
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDirURL.path)
            }
        }

        // Read existing authorized_keys or create empty
        var existingContent = ""
        if fm.fileExists(atPath: authKeysURL.path) {
            existingContent = try String(contentsOf: authKeysURL, encoding: .utf8)

            // Check for duplicates (compare key type + key data, ignore comment)
            let existingKeys = existingContent
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }

            let newKeyBase = publicKey.trimmingCharacters(in: .whitespaces)
            for existing in existingKeys {
                let existingParts = existing.components(separatedBy: " ")
                let newParts = newKeyBase.components(separatedBy: " ")
                if existingParts.count >= 2 && newParts.count >= 2
                    && existingParts[0] == newParts[0]
                    && existingParts[1] == newParts[1] {
                    throw InstallError.duplicate
                }
            }
        }

        // Build the entry: comment line + key line
        let keyLine = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateStr = ISO8601DateFormatter().string(from: Date())
        let commentLine = "\(agenthubKeyMarker) \(dateStr)"

        let entry = "\(commentLine)\n\(keyLine)\n"
        let newContent: String
        if existingContent.isEmpty {
            newContent = entry
        } else if existingContent.hasSuffix("\n") {
            newContent = existingContent + entry
        } else {
            newContent = existingContent + "\n" + entry
        }

        try newContent.write(to: authKeysURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authKeysURL.path)
    }

    /// Returns keys that were added by AgentHub (preceded by the marker comment).
    static func agenthubKeys() -> [AgentHubSSHKey] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: authKeysURL.path),
              let content = try? String(contentsOf: authKeysURL, encoding: .utf8)
        else { return [] }

        let lines = content.components(separatedBy: .newlines)
        var keys: [AgentHubSSHKey] = []

        for (i, line) in lines.enumerated() {
            guard line.hasPrefix(agenthubKeyMarker) else { continue }
            let dateStr = String(line.dropFirst(agenthubKeyMarker.count)).trimmingCharacters(in: .whitespaces)

            // Next non-empty line should be the key
            let nextIndex = i + 1
            guard nextIndex < lines.count else { continue }
            let keyLine = lines[nextIndex].trimmingCharacters(in: .whitespaces)
            guard !keyLine.isEmpty && !keyLine.hasPrefix("#") else { continue }

            let parts = keyLine.components(separatedBy: " ")
            guard parts.count >= 2 else { continue }

            let keyType = parts[0]
            let keyData = parts[1]
            let comment = parts.count > 2 ? parts[2...].joined(separator: " ") : ""

            keys.append(AgentHubSSHKey(
                id: "\(keyType) \(keyData)",
                fullLine: keyLine,
                keyType: keyType,
                keyData: keyData,
                comment: comment,
                addedDate: dateStr.isEmpty ? nil : dateStr
            ))
        }

        return keys
    }

    /// Removes a specific key (and its marker comment) from authorized_keys.
    static func removeKey(_ key: AgentHubSSHKey) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: authKeysURL.path) else { return }

        let content = try String(contentsOf: authKeysURL, encoding: .utf8)
        var lines = content.components(separatedBy: .newlines)

        // Find and remove the key line and its preceding marker comment
        var indicesToRemove: [Int] = []
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.components(separatedBy: " ")
            if parts.count >= 2 && parts[0] == key.keyType && parts[1] == key.keyData {
                indicesToRemove.append(i)
                // Also remove preceding marker comment if present
                if i > 0 && lines[i - 1].hasPrefix(agenthubKeyMarker) {
                    indicesToRemove.append(i - 1)
                }
                break
            }
        }

        for i in indicesToRemove.sorted().reversed() {
            lines.remove(at: i)
        }

        // Remove trailing empty lines, then ensure single trailing newline
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        let newContent = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"

        try newContent.write(to: authKeysURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authKeysURL.path)
    }
}

// MARK: - Camera Preview (NSViewRepresentable)

struct CameraPreviewView: NSViewRepresentable {
    let cameraID: String?
    let onQRCodeDetected: (String) -> Void

    func makeNSView(context: Context) -> CameraContainerView {
        let view = CameraContainerView()
        view.wantsLayer = true
        context.coordinator.startCapture(in: view, cameraID: cameraID, onDetected: onQRCodeDetected)
        return view
    }

    func updateNSView(_ nsView: CameraContainerView, context: Context) {}

    static func dismantleNSView(_ nsView: CameraContainerView, coordinator: Coordinator) {
        coordinator.stopCapture()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class CameraContainerView: NSView {
        override func layout() {
            super.layout()
            layer?.sublayers?.first?.frame = bounds
        }
    }

    class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private var captureSession: AVCaptureSession?
        private var onDetected: ((String) -> Void)?
        private nonisolated(unsafe) var hasDetected = false
        private nonisolated(unsafe) var isProcessing = false
        private let processingQueue = DispatchQueue(label: "qr-scanner")

        func startCapture(in view: CameraContainerView, cameraID: String?, onDetected: @escaping (String) -> Void) {
            self.onDetected = onDetected

            let session = AVCaptureSession()
            session.sessionPreset = .high

            let device: AVCaptureDevice?
            if let cameraID {
                device = AVCaptureDevice(uniqueID: cameraID)
            } else {
                device = AVCaptureDevice.default(for: .video)
            }

            guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return }
            guard session.canAddInput(input) else { return }
            session.addInput(input)

            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
            videoOutput.alwaysDiscardsLateVideoFrames = true
            guard session.canAddOutput(videoOutput) else { return }
            session.addOutput(videoOutput)

            let previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.frame = view.bounds
            previewLayer.videoGravity = .resizeAspectFill
            view.layer?.addSublayer(previewLayer)

            self.captureSession = session

            Task.detached {
                session.startRunning()
            }
        }

        func stopCapture() {
            let session = captureSession
            captureSession = nil
            Task.detached {
                session?.stopRunning()
            }
        }

        nonisolated func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            // Skip if already detected or if previous frame is still being processed
            guard !hasDetected, !isProcessing else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            isProcessing = true

            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try? handler.perform([request])

            defer { isProcessing = false }

            guard let results = request.results else { return }
            for barcode in results {
                guard barcode.symbology == .qr,
                      let payload = barcode.payloadStringValue
                else { continue }

                hasDetected = true
                DispatchQueue.main.async {
                    self.onDetected?(payload)
                }
                return
            }
        }
    }
}
