import Foundation

/// Runs the post-recording stages for one meeting. Each stage is resumable:
/// a meeting that failed at summarizing restarts at summarizing, not at mixing.
public actor PipelineCoordinator {
    private let store: MeetingStore
    private let transcriber: any Transcriber
    private let summarizer: any Summarizer
    private let onStageChange: (@Sendable (MeetingMetadata) -> Void)?

    public init(
        store: MeetingStore,
        transcriber: any Transcriber,
        summarizer: any Summarizer,
        onStageChange: (@Sendable (MeetingMetadata) -> Void)? = nil
    ) {
        self.store = store
        self.transcriber = transcriber
        self.summarizer = summarizer
        self.onStageChange = onStageChange
    }

    /// Advances the meeting as far as it can. Returns the final metadata rather
    /// than throwing on a stage failure: a failed stage is a recorded state, not
    /// an exception, so the UI can offer a retry. Throws only if the meeting's
    /// metadata cannot be read at all.
    @discardableResult
    public func process(meetingID id: UUID) async throws -> MeetingMetadata {
        var metadata = try store.read(id: id)
        let resumeFrom: MeetingStage =
            metadata.stage == .failed ? (metadata.failedStage ?? .mixing) : .mixing

        do {
            if shouldRun(.mixing, resumingFrom: resumeFrom) {
                metadata = try advance(metadata, to: .mixing)
                try mix(id: id)
            }
            if shouldRun(.transcribing, resumingFrom: resumeFrom) {
                metadata = try advance(metadata, to: .transcribing)
                try await runTranscription(id: id)
            }
            if shouldRun(.summarizing, resumingFrom: resumeFrom) {
                metadata = try advance(metadata, to: .summarizing)
                let summary = try await runSummary(id: id)
                metadata.title = summary.title
            }
            metadata.failureReason = nil
            metadata.failedStage = nil
            return try advance(metadata, to: .complete)
        } catch {
            let failedStage = metadata.stage
            metadata.stage = .failed
            metadata.failedStage = failedStage
            metadata.failureReason =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            try store.write(metadata)
            onStageChange?(metadata)
            return metadata
        }
    }

    // MARK: - Stages

    private func mix(id: UUID) throws {
        try AudioMixer.mix(
            micURL: store.micURL(for: id),
            systemURL: store.systemURL(for: id),
            outputURL: store.mixedURL(for: id)
        )
    }

    private func runTranscription(id: UUID) async throws {
        let transcript = try await transcriber.transcribe(audioFileAt: store.mixedURL(for: id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: store.transcriptURL(for: id), options: .atomic)
    }

    private func runSummary(id: UUID) async throws -> MeetingSummary {
        let transcript = try JSONDecoder().decode(
            Transcript.self, from: Data(contentsOf: store.transcriptURL(for: id)))
        let summary = try await summarizer.summarize(transcript)
        try Data(summary.markdown.utf8).write(to: store.summaryURL(for: id), options: .atomic)
        return summary
    }

    // MARK: - Helpers

    private static let order: [MeetingStage] = [.mixing, .transcribing, .summarizing]

    private func shouldRun(_ stage: MeetingStage, resumingFrom resume: MeetingStage) -> Bool {
        guard let stageIndex = Self.order.firstIndex(of: stage),
            let resumeIndex = Self.order.firstIndex(of: resume)
        else { return true }
        return stageIndex >= resumeIndex
    }

    private func advance(
        _ metadata: MeetingMetadata, to stage: MeetingStage
    ) throws -> MeetingMetadata {
        var updated = metadata
        updated.stage = stage
        try store.write(updated)
        onStageChange?(updated)
        return updated
    }
}
