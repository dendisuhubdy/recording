import Foundation
import Testing

@testable import MeetingCore

private func decodeBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let sampleTranscript = Transcript(segments: [
    TranscriptSegment(start: 0, end: 4, text: "We should cut billing from Q3.")
])

@Test func requestTargetsTheMessagesEndpointWithRequiredHeaders() throws {
    let summarizer = ClaudeSummarizer(apiKey: "sk-test-key")

    let request = try summarizer.makeRequest(for: sampleTranscript)

    #expect(request.url == URL(string: "https://api.anthropic.com/v1/messages"))
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test-key")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
}

@Test func requestUsesOpusFiveAndStreams() throws {
    let body = try decodeBody(ClaudeSummarizer(apiKey: "k").makeRequest(for: sampleTranscript))

    #expect(body["model"] as? String == "claude-opus-5")
    #expect(body["stream"] as? Bool == true)
    #expect(body["max_tokens"] as? Int == 32_000)
}

@Test func requestDeclaresTheSummarySchema() throws {
    let body = try decodeBody(ClaudeSummarizer(apiKey: "k").makeRequest(for: sampleTranscript))

    let outputConfig = try #require(body["output_config"] as? [String: Any])
    let format = try #require(outputConfig["format"] as? [String: Any])
    #expect(format["type"] as? String == "json_schema")

    let schema = try #require(format["schema"] as? [String: Any])
    let required = try #require(schema["required"] as? [String])
    #expect(Set(required) == ["title", "summary", "decisions", "action_items", "open_questions"])
    #expect(schema["additionalProperties"] as? Bool == false)
}

@Test func requestSendsTheTimestampedTranscriptAsTheUserMessage() throws {
    let body = try decodeBody(ClaudeSummarizer(apiKey: "k").makeRequest(for: sampleTranscript))

    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    #expect(messages[0]["role"] as? String == "user")
    let content = try #require(messages[0]["content"] as? String)
    #expect(content.contains("[00:00] We should cut billing from Q3."))
}

@Test func requestRejectsAnEmptyAPIKeyBeforeHittingTheNetwork() {
    #expect(throws: SummarizerError.missingAPIKey) {
        _ = try ClaudeSummarizer(apiKey: "").makeRequest(for: sampleTranscript)
    }
}

@Test func requestRejectsAnEmptyTranscript() {
    #expect(throws: SummarizerError.emptyTranscript) {
        _ = try ClaudeSummarizer(apiKey: "k").makeRequest(for: Transcript(segments: []))
    }
}

@Test func summaryModelDecodesSnakeCasedAPIFields() throws {
    let json = """
        {
          "title": "Q3 roadmap",
          "summary": "Billing was cut.",
          "decisions": ["Cut billing"],
          "action_items": [{"owner": "Dendi", "task": "Update the roadmap doc"}],
          "open_questions": ["Who owns migration?"]
        }
        """

    let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))

    #expect(summary.title == "Q3 roadmap")
    #expect(summary.actionItems == [.init(owner: "Dendi", task: "Update the roadmap doc")])
    #expect(summary.openQuestions == ["Who owns migration?"])
}
