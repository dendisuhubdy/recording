import Foundation

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    public var segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment]) {
        self.segments = segments
    }

    // Encoded as a bare array of segments so `transcript.json` matches the
    // format documented in the design doc, rather than an object wrapper.
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [TranscriptSegment] = []
        while !container.isAtEnd {
            decoded.append(try container.decode(TranscriptSegment.self))
        }
        segments = decoded
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for segment in segments { try container.encode(segment) }
    }

    /// All segment text joined into one paragraph.
    public var plainText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// One line per segment, prefixed `[mm:ss]`. This is what gets sent to the
    /// model, so it can refer to points in the meeting by time.
    public var timestampedText: String {
        segments.map { segment in
            let total = Int(segment.start.rounded(.down))
            let stamp = String(format: "[%02d:%02d]", total / 60, total % 60)
            return "\(stamp) \(segment.text)"
        }.joined(separator: "\n")
    }
}
