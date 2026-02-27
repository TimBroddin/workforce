# QR Code SSH Key Scanner

## Summary

Add a QR code scanner to the macOS Workforce app's Settings > Remote Hosts section that reads SSH public keys displayed by the iOS Workforce app and adds them to `~/.ssh/authorized_keys`.

## Architecture

### New Files

- `Workforce/Workforce/Views/QRKeyScannerView.swift` — Scanner sheet + camera preview

### Modified Files

- `Workforce/Workforce/Views/SettingsView.swift` — Add "iOS Device Keys" section with scan button
- `Workforce/Workforce.xcodeproj/project.pbxproj` — Reference new files + Info.plist
- `Workforce/Workforce/Info.plist` (new) — Camera usage description

### Components

1. **QRKeyScannerView** (sheet) — Camera preview + scan state machine
2. **CameraPreviewView** (NSViewRepresentable) — Wraps AVCaptureVideoPreviewLayer in NSView
3. **SSHKeyInstaller** (helper) — Manages ~/.ssh/authorized_keys file operations

### QR Payload Format

```json
{"type": "workforce-ssh-key", "publicKey": "ssh-ed25519 AAAA... WorkforceiOS"}
```

### Flow

1. User clicks "Scan iOS Device Key" in Settings > Remote Hosts
2. Sheet opens with live camera preview
3. AVCaptureMetadataOutput detects QR code with `.qr` type
4. Parse JSON, validate `type` field equals `workforce-ssh-key`
5. Validate key format (must start with `ssh-ed25519`, `ssh-rsa`, `ssh-ecdsa`, etc.)
6. Show confirmation: key type + fingerprint preview
7. On confirm: check duplicates, append to `~/.ssh/authorized_keys`
8. Ensure `~/.ssh` has 700 permissions, `authorized_keys` has 600
9. Show success/error, dismiss sheet

### Security

- Key format validation (prefix check)
- Duplicate detection before appending
- Directory/file permission enforcement (700/600)
- Camera permission via NSCameraUsageDescription in Info.plist

### UI Placement

Separate `Section("iOS Device Keys")` below the host list in RemoteHostsSettingsView.
