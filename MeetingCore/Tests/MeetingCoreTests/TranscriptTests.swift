import Foundation
import Testing

@testable import MeetingCore

@Test func transcriptRoundTripsThroughJSON() throws {
    let transcript = Transcript(segments: [
        TranscriptSegment(start: 0, end: 3.5, text: "Let's start."),
        TranscriptSegment(start: 3.5, end: 9, text: "Agenda is billing."),
    ])

    let data = try JSONEncoder().encode(transcript)
    let decoded = try JSONDecoder().decode(Transcript.self, from: data)

    #expect(decoded == transcript)
}

@Test func transcriptEncodesAsATopLevelArray() throws {
    // The spec documents transcript.json as a bare array of segments, not an
    // object wrapping them. Keep the on-disk format matching the spec.
    let transcript = Transcript(segments: [
        TranscriptSegment(start: 0, end: 1, text: "Hi")
    ])

    let data = try JSONEncoder().encode(transcript)
    let parsed = try JSONSerialization.jsonObject(with: data)

    let array = try #require(parsed as? [[String: Any]])
    #expect(array.count == 1)
    #expect(array[0]["text"] as? String == "Hi")
}

@Test func plainTextJoinsSegmentsWithSpaces() {
    let transcript = Transcript(segments: [
        TranscriptSegment(start: 0, end: 1, text: "Hello"),
        TranscriptSegment(start: 1, end: 2, text: "world"),
    ])

    #expect(transcript.plainText == "Hello world")
}

@Test func timestampedTextPrefixesEachSegmentWithMinutesAndSeconds() {
    let transcript = Transcript(segments: [
        TranscriptSegment(start: 0, end: 1, text: "Opening"),
        TranscriptSegment(start: 125, end: 130, text: "Later point"),
    ])

    #expect(transcript.timestampedText == "[00:00] Opening\n[02:05] Later point")
}

@Test func emptyTranscriptProducesEmptyText() {
    #expect(Transcript(segments: []).plainText == "")
    #expect(Transcript(segments: []).timestampedText == "")
}
