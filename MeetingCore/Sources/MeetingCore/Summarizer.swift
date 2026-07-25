import Foundation

public protocol Summarizer: Sendable {
    func summarize(_ transcript: Transcript) async throws -> MeetingSummary
}

public enum SummarizerError: Error, Equatable {
    case missingAPIKey
    case emptyTranscript
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    /// The model declined the request. Retrying the identical request will not help.
    case refused(category: String?)
    case httpError(status: Int)
    case malformedResponse(String)
}

extension SummarizerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Claude API key. Add one in Settings."
        case .emptyTranscript:
            return "The transcript is empty, so there is nothing to summarize."
        case .unauthorized:
            return "The Claude API rejected the key. Check it in Settings."
        case .rateLimited(let retryAfter):
            guard let retryAfter else { return "Rate limited by the Claude API." }
            return "Rate limited by the Claude API. Retry in \(Int(retryAfter))s."
        case .refused(let category):
            let suffix = category.map { " (\($0))" } ?? ""
            return "The model declined to summarize this meeting\(suffix)."
        case .httpError(let status):
            return "The Claude API returned HTTP \(status)."
        case .malformedResponse:
            return "The Claude API response could not be parsed."
        }
    }
}
