import Foundation

public enum MeetingStage: String, Codable, Equatable, Sendable, CaseIterable {
    case recording
    case mixing
    case transcribing
    case summarizing
    case complete
    case failed
}

public struct MeetingMetadata: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var date: Date
    public var duration: TimeInterval
    public var stage: MeetingStage
    /// Human-readable description of the last failure. Never contains secrets.
    public var failureReason: String?
    /// The stage that failed, so a retry can resume from the right place.
    public var failedStage: MeetingStage?

    public init(
        id: UUID,
        title: String,
        date: Date,
        duration: TimeInterval = 0,
        stage: MeetingStage = .recording,
        failureReason: String? = nil,
        failedStage: MeetingStage? = nil
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.stage = stage
        self.failureReason = failureReason
        self.failedStage = failedStage
    }

    /// Placeholder shown in the library until the model supplies a real title.
    public static func defaultTitle(for date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
