import Foundation
import Testing

@testable import MeetingCore

private let transcript = Transcript(segments: [
    TranscriptSegment(start: 0, end: 4, text: "We should cut billing from Q3.")
])

private func summarizer(for url: URL) -> ClaudeSummarizer {
    ClaudeSummarizer(apiKey: "sk-test", session: StubURLProtocol.makeSession(), endpoint: url)
}

/// Builds one `content_block_delta` SSE line carrying `text`.
private func textDelta(_ text: String) -> String {
    let payload: [String: Any] = [
        "type": "content_block_delta",
        "delta": ["type": "text_delta", "text": text],
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload)
    return "data: \(String(decoding: data, as: UTF8.self))\n\n"
}

private func messageDelta(stopReason: String) -> String {
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(stopReason)\"}}\n\n"
}

@Test func assemblesSummaryFromDeltasSplitAcrossChunks() async throws {
    let json = """
        {"title":"Cut billing from Q3","summary":"The team dropped billing.",\
        "decisions":["Cut billing"],\
        "action_items":[{"owner":"Dendi","task":"Update the roadmap"}],\
        "open_questions":[]}
        """
    let midpoint = json.index(json.startIndex, offsetBy: json.count / 2)
    let url = StubURLProtocol.register(
        .init(chunks: [
            textDelta(String(json[json.startIndex..<midpoint])),
            textDelta(String(json[midpoint...])),
            messageDelta(stopReason: "end_turn"),
        ]))

    let summary = try await summarizer(for: url).summarize(transcript)

    #expect(summary.title == "Cut billing from Q3")
    #expect(summary.decisions == ["Cut billing"])
    #expect(summary.actionItems == [.init(owner: "Dendi", task: "Update the roadmap")])
    #expect(summary.openQuestions.isEmpty)
}

@Test func ignoresNonTextEventsInTheStream() async throws {
    let json = """
        {"title":"T","summary":"S","decisions":[],"action_items":[],"open_questions":[]}
        """
    let url = StubURLProtocol.register(
        .init(chunks: [
            "event: message_start\ndata: {\"type\":\"message_start\"}\n\n",
            "data: {\"type\":\"content_block_start\",\"index\":0}\n\n",
            textDelta(json),
            "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
            messageDelta(stopReason: "end_turn"),
            "data: [DONE]\n\n",
        ]))

    let summary = try await summarizer(for: url).summarize(transcript)

    #expect(summary.title == "T")
}

@Test func surfacesRefusalRatherThanFailingToParse() async {
    let url = StubURLProtocol.register(.init(chunks: [messageDelta(stopReason: "refusal")]))

    await #expect(throws: SummarizerError.refused(category: nil)) {
        _ = try await summarizer(for: url).summarize(transcript)
    }
}

@Test func surfacesUnauthorized() async {
    let url = StubURLProtocol.register(.init(status: 401))

    await #expect(throws: SummarizerError.unauthorized) {
        _ = try await summarizer(for: url).summarize(transcript)
    }
}

@Test func surfacesRateLimitWithRetryAfter() async {
    let url = StubURLProtocol.register(.init(status: 429, headers: ["retry-after": "12"]))

    await #expect(throws: SummarizerError.rateLimited(retryAfter: 12)) {
        _ = try await summarizer(for: url).summarize(transcript)
    }
}

@Test func surfacesOtherHTTPErrors() async {
    let url = StubURLProtocol.register(.init(status: 529))

    await #expect(throws: SummarizerError.httpError(status: 529)) {
        _ = try await summarizer(for: url).summarize(transcript)
    }
}

@Test func reportsMalformedJSONRatherThanCrashing() async {
    let url = StubURLProtocol.register(
        .init(chunks: [
            textDelta("{\"title\": \"unterminated"),
            messageDelta(stopReason: "end_turn"),
        ]))

    await #expect(throws: SummarizerError.self) {
        _ = try await summarizer(for: url).summarize(transcript)
    }
}
