import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum PermissionStatus: Equatable {
    case granted
    case denied
    case undetermined
}

enum PermissionKind: Equatable {
    case microphone
    case screenRecording

    var settingsURL: URL {
        switch self {
        case .microphone:
            return URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .screenRecording:
            return URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )!
        }
    }

    var explanation: String {
        switch self {
        case .microphone:
            return "Meeting Recorder needs microphone access to capture your side of the meeting."
        case .screenRecording:
            return """
                Meeting Recorder needs Screen Recording access to capture the audio of \
                other participants. It records audio only — no video is saved.
                """
        }
    }
}

enum PermissionChecker {
    static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// There is no direct query for ScreenCaptureKit authorization, so this
    /// probes by asking for shareable content — the same call that triggers the
    /// system prompt.
    static func screenRecordingStatus() async -> PermissionStatus {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            return .granted
        } catch {
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
    }

    static func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}
