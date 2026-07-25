import AVFoundation
import Foundation
import Testing

@testable import MeetingCore

/// Thread-safe collector for stage-change callbacks.
private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [MeetingStage] = []

    func record(_ metadata: MeetingMetadata) {
        lock.lock()
        stages.append(metadata.stage)
        lock.unlock()
    }

    var recorded: [MeetingStage] {
        lock.lock()
        defer { lock.unlock() }
        return stages
    }
}

/// Creates a meeting folder with two short, valid raw audio files.
private func makeReadyMeeting(in store: MeetingStore) throws -> UUID {
    let id = UUID()
    _ = try store.createMeeting(id: id, date: .now)
    for url in [store.micURL(for: id), store.systemURL(for: id)] {
        let format = AudioMixer.processingFormat
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for i in 0..<4800 { buffer.floatChannelData![0][i] = 0.1 }
        try file.write(from: buffer)
    }
    return id
}

@Test func happyPathWritesEveryArtifactAndCompletes() async throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)
    let id = try makeReadyMeeting(in: store)
    let log = StageLog()
    let coordinator = PipelineCoordinator(
        store: store,
        transcriber: FakeTranscriber(returning: .fixture),
        summarizer: FakeSummarizer(returning: .fixture),
        onStageChange: { log.record($0) }
    )

    let final = try await coordinator.process(meetingID: id)

    #expect(final.stage == .complete)
    #expect(final.title == "Cut billing from Q3")
    #expect(final.failureReason == nil)
    #expect(log.recorded == [.mixing, .transcribing, .summarizing, .complete])

    #expect(FileManager.default.fileExists(atPath: store.mixedURL(for: id).path))
    #expect(FileManager.default.fileExists(atPath: store.transcriptURL(for: id).path))
    #expect(FileManager.default.fileExists(atPath: store.summaryURL(for: id).path))
    #expect(try store.read(id: id).stage == .complete)
}

@Test func transcriptionFailureKeepsAudioAndRecordsTheFailedStage() async throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)
    let id = try makeReadyMeeting(in: store)
    let coordinator = PipelineCoordinator(
        store: store,
        transcriber: FakeTranscriber(failingWith: .modelUnavailable),
        summarizer: FakeSummarizer(returning: .fixture)
    )

    let final = try await coordinator.process(meetingID: id)

    #expect(final.stage == .failed)
    #expect(final.failedStage == .transcribing)
    #expect(final.failureReason != nil)
    // Audio is sacred — mixing succeeded, so its output must survive.
    #expect(FileManager.default.fileExists(atPath: store.micURL(for: id).path))
    #expect(FileManager.default.fileExists(atPath: store.mixedURL(for: id).path))
    #expect(!FileManager.default.fileExists(atPath: store.summaryURL(for: id).path))
}

@Test func summaryFailureStillLeavesAReadableTranscript() async throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)
    let id = try makeReadyMeeting(in: store)
    let coordinator = PipelineCoordinator(
        store: store,
        transcriber: FakeTranscriber(returning: .fixture),
        summarizer: FakeSummarizer(failingWith: .unauthorized)
    )

    let final = try await coordinator.process(meetingID: id)

    #expect(final.stage == .failed)
    #expect(final.failedStage == .summarizing)
    #expect(FileManager.default.fileExists(atPath: store.transcriptURL(for: id).path))

    let saved = try JSONDecoder().decode(
        Transcript.self, from: Data(contentsOf: store.transcriptURL(for: id)))
    #expect(saved == .fixture)
}

@Test func retryAfterSummaryFailureSkipsMixingAndTranscription() async throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)
    let id = try makeReadyMeeting(in: store)

    _ = try await PipelineCoordinator(
        store: store,
        transcriber: FakeTranscriber(returning: .fixture),
        summarizer: FakeSummarizer(failingWith: .unauthorized)
    ).process(meetingID: id)

    // A transcriber that would fail if called proves the retry resumed at the
    // summarizing stage rather than starting over.
    let log = StageLog()
    let final = try await PipelineCoordinator(
        store: store,
        transcriber: FakeTranscriber(failingWith: .modelUnavailable),
        summarizer: FakeSummarizer(returning: .fixture),
        onStageChange: { log.record($0) }
    ).process(meetingID: id)

    #expect(final.stage == .complete)
    #expect(log.recorded == [.summarizing, .complete])
}

@Test func missingRawAudioFailsAtTheMixingStage() async throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)
    let id = UUID()
    _ = try store.createMeeting(id: id, date: .now)  // no audio files written

    let final = try await PipelineCoordinator(
        store: store,
        transcriber: FakeTranscriber(returning: .fixture),
        summarizer: FakeSummarizer(returning: .fixture)
    ).process(meetingID: id)

    #expect(final.stage == .failed)
    #expect(final.failedStage == .mixing)
}
