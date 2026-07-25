import Foundation

public protocol Transcriber: Sendable {
    func transcribe(audioFileAt url: URL) async throws -> Transcript
}

public enum TranscriberError: Error, Equatable {
    case localeUnsupported(String)
    case modelUnavailable
    case audioUnreadable(String)
    case analysisFailed(String)
}

extension TranscriberError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .localeUnsupported(let identifier):
            return "On-device transcription does not support \(identifier)."
        case .modelUnavailable:
            return "The speech model is not installed and could not be downloaded."
        case .audioUnreadable(let detail):
            return "The mixed audio file could not be read: \(detail)"
        case .analysisFailed(let detail):
            return "Transcription failed: \(detail)"
        }
    }
}
