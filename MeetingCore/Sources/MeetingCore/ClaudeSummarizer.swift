import Foundation

public struct ClaudeSummarizer: Summarizer {
    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let apiKey: String
    let session: URLSession
    let endpoint: URL

    public init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: URL = ClaudeSummarizer.defaultEndpoint
    ) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
    }

    static let systemPrompt = """
        You are summarizing a transcript of a meeting. The transcript comes from \
        automatic speech recognition of a single mixed audio track, so it has no \
        speaker labels and may contain transcription errors. Infer who is speaking \
        from context where you reasonably can, and do not invent names you cannot \
        support from the text.

        Write the summary for someone who missed the meeting and wants to know what \
        happened and what is now expected of them. Lead with substance. Record a \
        decision only if the meeting actually settled it, and an action item only if \
        someone actually committed to it — an empty list is a correct answer. If an \
        action item's owner was never named, use "unassigned".

        The title should name the specific outcome, not the topic: prefer "Cut billing \
        from the Q3 roadmap" over "Q3 roadmap discussion".
        """

    /// Computed rather than a `static let`: a stored `[String: Any]` is not
    /// Sendable, so Swift 6 treats it as mutable global state and rejects it.
    /// This is a literal built once per request — the cost is irrelevant next
    /// to the network call it describes.
    static var responseSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "summary": ["type": "string"],
                "decisions": ["type": "array", "items": ["type": "string"]],
                "action_items": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "owner": ["type": "string"],
                            "task": ["type": "string"],
                        ],
                        "required": ["owner", "task"],
                        "additionalProperties": false,
                    ],
                ],
                "open_questions": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["title", "summary", "decisions", "action_items", "open_questions"],
            "additionalProperties": false,
        ]
    }

    public func makeRequest(for transcript: Transcript) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw SummarizerError.missingAPIKey }
        guard !transcript.segments.isEmpty else { throw SummarizerError.emptyTranscript }

        let body: [String: Any] = [
            "model": "claude-opus-5",
            "max_tokens": 32_000,
            "stream": true,
            "system": Self.systemPrompt,
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": Self.responseSchema,
                ]
            ],
            "messages": [
                ["role": "user", "content": transcript.timestampedText]
            ],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func summarize(_ transcript: Transcript) async throws -> MeetingSummary {
        let request = try makeRequest(for: transcript)
        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw SummarizerError.malformedResponse("no HTTP response")
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw SummarizerError.unauthorized
        case 429:
            let retryAfter =
                http.value(forHTTPHeaderField: "retry-after")
                .flatMap(TimeInterval.init)
            throw SummarizerError.rateLimited(retryAfter: retryAfter)
        default:
            throw SummarizerError.httpError(status: http.statusCode)
        }

        var text = ""
        var stopReason: String?
        var refusalCategory: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            guard payload != "[DONE]",
                let data = payload.data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            switch event["type"] as? String {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                    delta["type"] as? String == "text_delta",
                    let chunk = delta["text"] as? String
                {
                    text += chunk
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any] {
                    stopReason = delta["stop_reason"] as? String
                    if let details = delta["stop_details"] as? [String: Any] {
                        refusalCategory = details["category"] as? String
                    }
                }
            default:
                continue
            }
        }

        // Check the refusal before parsing — on a refusal there is no JSON to parse,
        // and reporting a parse failure would hide the real reason.
        if stopReason == "refusal" {
            throw SummarizerError.refused(category: refusalCategory)
        }

        guard let data = text.data(using: .utf8) else {
            throw SummarizerError.malformedResponse(text)
        }
        do {
            return try JSONDecoder().decode(MeetingSummary.self, from: data)
        } catch {
            throw SummarizerError.malformedResponse(text)
        }
    }
}
