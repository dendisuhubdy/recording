import Foundation
import MeetingCore
import SwiftData

@Model
final class MeetingRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var stageRaw: String
    var failureReason: String?

    var stage: MeetingStage {
        get { MeetingStage(rawValue: stageRaw) ?? .failed }
        set { stageRaw = newValue.rawValue }
    }

    init(metadata: MeetingMetadata) {
        id = metadata.id
        title = metadata.title
        date = metadata.date
        duration = metadata.duration
        stageRaw = metadata.stage.rawValue
        failureReason = metadata.failureReason
    }

    func apply(_ metadata: MeetingMetadata) {
        title = metadata.title
        date = metadata.date
        duration = metadata.duration
        stageRaw = metadata.stage.rawValue
        failureReason = metadata.failureReason
    }
}
