import Foundation

@testable import MeetingCore

struct FakeTranscriber: Transcriber {
    var result: Result<Transcript, TranscriberError>

    init(returning transcript: Transcript) { result = .success(transcript) }
    init(failingWith error: TranscriberError) { result = .failure(error) }

    func transcribe(audioFileAt url: URL) async throws -> Transcript {
        try result.get()
    }
}

struct FakeSummarizer: Summarizer {
    var result: Result<MeetingSummary, SummarizerError>

    init(returning summary: MeetingSummary) { result = .success(summary) }
    init(failingWith error: SummarizerError) { result = .failure(error) }

    func summarize(_ transcript: Transcript) async throws -> MeetingSummary {
        try result.get()
    }
}

extension MeetingSummary {
    static let fixture = MeetingSummary(
        title: "Cut billing from Q3",
        summary: "The team dropped billing from the Q3 roadmap.",
        decisions: ["Cut billing"],
        actionItems: [.init(owner: "Dendi", task: "Update the roadmap doc")],
        openQuestions: []
    )
}

extension Transcript {
    static let fixture = Transcript(segments: [
        TranscriptSegment(start: 0, end: 4, text: "We should cut billing from Q3.")
    ])
}
