# Meeting Recorder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS app with a red record button that captures a meeting (microphone + system audio), transcribes it on-device, and summarizes it with the Claude API.

**Architecture:** All logic that can be tested without hardware or network lives in a local Swift package, `MeetingCore`, driven by `swift test` from the command line. A thin Xcode app target owns the pieces that genuinely need an app bundle — ScreenCaptureKit capture, TCC permissions, SwiftUI, Keychain — and depends on the package. Recording writes two raw passthrough files; mixing, transcription, and summarization all happen after stop, as independently retryable stages.

**Tech Stack:** Swift 6.3, SwiftUI, SwiftData, Swift Testing, ScreenCaptureKit, Speech (`SpeechAnalyzer`), AVFoundation, `URLSession`.

**Spec:** `docs/superpowers/specs/2026-07-25-meeting-recorder-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **Platform floor:** macOS 26.0. `Package.swift` declares `platforms: [.macOS(.v26)]` and `// swift-tools-version: 6.2`.
- **Test framework:** Swift Testing (`import Testing`, `@Test`, `#expect`). Not XCTest.
- **Tests run in parallel.** Never share mutable global state between tests. Fixtures are per-test (unique temp directory, unique stub URL). This is not stylistic — it was observed breaking these exact tests during design.
- **Claude model id:** `claude-opus-5`, exactly. No date suffix.
- **Claude API version header:** `anthropic-version: 2023-06-01`.
- **No third-party dependencies.** There is no official Anthropic SDK for Swift; the API is called over raw `URLSession`.
- **The API key is only ever read from and written to the Keychain.** It must never appear in `meta.json`, `summary.md`, a log line, an error message, or a commit.
- **Audio is sacred.** No code path deletes or overwrites `mic.caf`, `system.caf`, or `mixed.m4a` on failure.
- **Storage root:** `~/Library/Application Support/MeetingRecorder/Meetings/<uuid>/`.
- **Commit after every task**, using the message given in that task's final step.

## File Structure

```
MeetingCore/                                  # SPM package — CLI-testable, no app bundle needed
  Package.swift
  Sources/MeetingCore/
    Transcript.swift                          # TranscriptSegment, Transcript
    MeetingMetadata.swift                     # MeetingStage, MeetingMetadata
    MeetingStore.swift                        # folder layout, meta.json, listing, deletion
    AudioMixer.swift                          # offline two-file mix + normalize
    MeetingSummary.swift                      # MeetingSummary, ActionItem
    Summarizer.swift                          # Summarizer protocol, SummarizerError
    ClaudeSummarizer.swift                    # request building + SSE streaming
    Transcriber.swift                         # Transcriber protocol, TranscriberError
    SpeechTranscriberEngine.swift             # SpeechAnalyzer-backed implementation
    PipelineCoordinator.swift                 # mixing → transcribing → summarizing state machine
  Tests/MeetingCoreTests/
    TranscriptTests.swift
    MeetingStoreTests.swift
    AudioMixerTests.swift
    ClaudeSummarizerRequestTests.swift
    ClaudeSummarizerStreamingTests.swift
    PipelineCoordinatorTests.swift
    Support/TempDirectory.swift               # per-test temp dir helper
    Support/StubURLProtocol.swift             # parallel-safe HTTP stub
    Support/Fakes.swift                       # FakeTranscriber, FakeSummarizer

MeetingRecorder/                              # Xcode app target
  MeetingRecorderApp.swift                    # @main, MenuBarExtra + Window
  RecordingEngine.swift                       # SCStream → mic.caf + system.caf
  CMSampleBuffer+PCM.swift                    # sample buffer → AVAudioPCMBuffer
  PermissionChecker.swift                     # pre-flight TCC checks
  MeetingLibrary.swift                        # SwiftData index + rebuild-from-disk
  MeetingRecord.swift                         # @Model
  KeychainStore.swift                         # API key storage
  AppModel.swift                              # observable app state, wires the pipeline
  Views/RecordButton.swift
  Views/MeetingListView.swift
  Views/MeetingDetailView.swift
  Views/SettingsView.swift
  Info.plist
  docs/manual-smoke-test.md                   # RecordingEngine checklist
```

**Note on SwiftData:** the spec calls for a SwiftData index alongside `meta.json`, with `meta.json` authoritative. Task 10 implements exactly that. Worth knowing while building: for a personal tool, scanning a few hundred meeting folders at launch is instant, so the index is a convenience rather than a necessity. If it proves to be friction during Task 10, dropping it and reading folders directly is a defensible simplification — raise it rather than working around it silently.

---

### Task 1: Package skeleton and transcript model

**Files:**
- Create: `MeetingCore/Package.swift`
- Create: `MeetingCore/Sources/MeetingCore/Transcript.swift`
- Test: `MeetingCore/Tests/MeetingCoreTests/TranscriptTests.swift`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: `TranscriptSegment(start: TimeInterval, end: TimeInterval, text: String)`; `Transcript(segments: [TranscriptSegment])` with `var plainText: String` and `var timestampedText: String`

- [ ] **Step 1: Create the package manifest**

Create `MeetingCore/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MeetingCore", targets: ["MeetingCore"])],
    targets: [
        .target(name: "MeetingCore"),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"]),
    ]
)
```

- [ ] **Step 2: Write the failing test**

Create `MeetingCore/Tests/MeetingCoreTests/TranscriptTests.swift`:

```swift
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
        TranscriptSegment(start: 0, end: 1, text: "Hi"),
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
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd MeetingCore && swift test`
Expected: FAIL — `cannot find 'Transcript' in scope`.

- [ ] **Step 4: Write the implementation**

Create `MeetingCore/Sources/MeetingCore/Transcript.swift`:

```swift
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd MeetingCore && swift test`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add MeetingCore/Package.swift MeetingCore/Sources MeetingCore/Tests
git commit -m "feat: add MeetingCore package and transcript model"
```

---

### Task 2: Meeting metadata and disk store

**Files:**
- Create: `MeetingCore/Sources/MeetingCore/MeetingMetadata.swift`
- Create: `MeetingCore/Sources/MeetingCore/MeetingStore.swift`
- Create: `MeetingCore/Tests/MeetingCoreTests/Support/TempDirectory.swift`
- Test: `MeetingCore/Tests/MeetingCoreTests/MeetingStoreTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1
- Produces:
  - `enum MeetingStage: String { recording, mixing, transcribing, summarizing, complete, failed }`
  - `struct MeetingMetadata { var id: UUID; var title: String; var date: Date; var duration: TimeInterval; var stage: MeetingStage; var failureReason: String? }`
  - `struct MeetingStore` with `init(root: URL)`, `static var defaultRoot: URL`, `func createMeeting(id:date:) throws -> MeetingMetadata`, `func write(_:) throws`, `func read(id:) throws -> MeetingMetadata`, `func allMeetings() throws -> [MeetingMetadata]`, `func delete(id:) throws`, and URL accessors `folder(for:)`, `micURL(for:)`, `systemURL(for:)`, `mixedURL(for:)`, `transcriptURL(for:)`, `summaryURL(for:)`

- [ ] **Step 1: Write the temp-directory test helper**

Each test gets its own directory — tests run in parallel and must not share paths.

Create `MeetingCore/Tests/MeetingCoreTests/Support/TempDirectory.swift`:

```swift
import Foundation

/// A unique directory that deletes itself when the test's reference is released.
final class TempDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = URL.temporaryDirectory.appending(path: "MeetingCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 2: Write the failing test**

Create `MeetingCore/Tests/MeetingCoreTests/MeetingStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import MeetingCore

@Test func createMeetingMakesFolderAndWritesMetadata() throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    let metadata = try store.createMeeting(id: id, date: date)

    #expect(metadata.id == id)
    #expect(metadata.stage == .recording)
    #expect(FileManager.default.fileExists(atPath: store.folder(for: id).path))

    let reread = try store.read(id: id)
    #expect(reread == metadata)
}

@Test func writeThenReadPreservesEveryField() throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)
    let id = UUID()
    var metadata = try store.createMeeting(id: id, date: .now)

    metadata.title = "Q3 roadmap"
    metadata.duration = 1830
    metadata.stage = .failed
    metadata.failureReason = "network offline"
    try store.write(metadata)

    #expect(try store.read(id: id) == metadata)
}

@Test func allMeetingsReturnsNewestFirst() throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)
    let older = try store.createMeeting(id: UUID(), date: Date(timeIntervalSince1970: 1000))
    let newer = try store.createMeeting(id: UUID(), date: Date(timeIntervalSince1970: 2000))

    let all = try store.allMeetings()

    #expect(all.map(\.id) == [newer.id, older.id])
}

@Test func allMeetingsSkipsFoldersWithUnreadableMetadata() throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)
    let good = try store.createMeeting(id: UUID(), date: .now)

    // A folder with corrupt metadata must not take down the whole listing.
    let junk = temp.url.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: junk.appending(path: "meta.json"))

    let all = try store.allMeetings()

    #expect(all.map(\.id) == [good.id])
}

@Test func allMeetingsIsEmptyWhenRootDoesNotExist() throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url.appending(path: "not-created-yet"))

    #expect(try store.allMeetings().isEmpty)
}

@Test func deleteRemovesTheWholeFolder() throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)
    let id = UUID()
    _ = try store.createMeeting(id: id, date: .now)

    try store.delete(id: id)

    #expect(!FileManager.default.fileExists(atPath: store.folder(for: id).path))
    #expect(try store.allMeetings().isEmpty)
}

@Test func fileURLsUseTheDocumentedNames() {
    let store = MeetingStore(root: URL(filePath: "/tmp/root"))
    let id = UUID()
    let folder = store.folder(for: id)

    #expect(store.micURL(for: id) == folder.appending(path: "mic.caf"))
    #expect(store.systemURL(for: id) == folder.appending(path: "system.caf"))
    #expect(store.mixedURL(for: id) == folder.appending(path: "mixed.m4a"))
    #expect(store.transcriptURL(for: id) == folder.appending(path: "transcript.json"))
    #expect(store.summaryURL(for: id) == folder.appending(path: "summary.md"))
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd MeetingCore && swift test`
Expected: FAIL — `cannot find 'MeetingStore' in scope`.

- [ ] **Step 4: Write the metadata model**

Create `MeetingCore/Sources/MeetingCore/MeetingMetadata.swift`:

```swift
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
```

- [ ] **Step 5: Write the store**

Create `MeetingCore/Sources/MeetingCore/MeetingStore.swift`:

```swift
import Foundation

public struct MeetingStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var defaultRoot: URL {
        URL.applicationSupportDirectory
            .appending(path: "MeetingRecorder")
            .appending(path: "Meetings")
    }

    // MARK: - Paths

    public func folder(for id: UUID) -> URL { root.appending(path: id.uuidString) }
    public func micURL(for id: UUID) -> URL { folder(for: id).appending(path: "mic.caf") }
    public func systemURL(for id: UUID) -> URL { folder(for: id).appending(path: "system.caf") }
    public func mixedURL(for id: UUID) -> URL { folder(for: id).appending(path: "mixed.m4a") }
    public func transcriptURL(for id: UUID) -> URL { folder(for: id).appending(path: "transcript.json") }
    public func summaryURL(for id: UUID) -> URL { folder(for: id).appending(path: "summary.md") }
    private func metadataURL(for id: UUID) -> URL { folder(for: id).appending(path: "meta.json") }

    // MARK: - Lifecycle

    @discardableResult
    public func createMeeting(id: UUID, date: Date) throws -> MeetingMetadata {
        try FileManager.default.createDirectory(
            at: folder(for: id), withIntermediateDirectories: true)
        let metadata = MeetingMetadata(
            id: id, title: MeetingMetadata.defaultTitle(for: date), date: date)
        try write(metadata)
        return metadata
    }

    public func write(_ metadata: MeetingMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: folder(for: metadata.id), withIntermediateDirectories: true)
        try encoder.encode(metadata).write(to: metadataURL(for: metadata.id), options: .atomic)
    }

    public func read(id: UUID) throws -> MeetingMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            MeetingMetadata.self, from: Data(contentsOf: metadataURL(for: id)))
    }

    /// Newest first. Folders whose metadata cannot be read are skipped rather
    /// than throwing — one corrupt meeting must not hide all the others.
    public func allMeetings() throws -> [MeetingMetadata] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        return folders
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? read(id: $0) }
            .sorted { $0.date > $1.date }
    }

    public func delete(id: UUID) throws {
        try FileManager.default.removeItem(at: folder(for: id))
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd MeetingCore && swift test`
Expected: PASS, 11 tests total.

- [ ] **Step 7: Commit**

```bash
git add MeetingCore/Sources/MeetingCore/MeetingMetadata.swift \
        MeetingCore/Sources/MeetingCore/MeetingStore.swift \
        MeetingCore/Tests/MeetingCoreTests/MeetingStoreTests.swift \
        MeetingCore/Tests/MeetingCoreTests/Support/TempDirectory.swift
git commit -m "feat: add meeting metadata model and on-disk store"
```

---

### Task 3: Offline audio mixer

The code below was prototyped and verified against real `AVAudioFile` I/O during design; the assertions are known to hold.

**Files:**
- Create: `MeetingCore/Sources/MeetingCore/AudioMixer.swift`
- Test: `MeetingCore/Tests/MeetingCoreTests/AudioMixerTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `struct MixReport { let peak: Float; let frameCount: AVAudioFramePosition; let didNormalize: Bool }`; `enum AudioMixer` with `static let processingFormat: AVAudioFormat`, `static func mixToFloatFile(a:b:outputURL:) throws -> MixReport`, `static func mix(micURL:systemURL:outputURL:) throws -> MixReport`

- [ ] **Step 1: Write the failing test**

Create `MeetingCore/Tests/MeetingCoreTests/AudioMixerTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import MeetingCore

private func writeConstant(_ value: Float, frames: Int, to url: URL) throws {
    let format = AudioMixer.processingFormat
    let file = try AVAudioFile(
        forWriting: url, settings: format.settings,
        commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames { buffer.floatChannelData![0][i] = value }
    try file.write(from: buffer)
}

private func readAll(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(
        start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

@Test func sumsBothSourcesWhenHeadroomRemains() throws {
    let temp = try TempDirectory()
    let a = temp.url.appending(path: "a.caf")
    let b = temp.url.appending(path: "b.caf")
    let out = temp.url.appending(path: "out.caf")
    try writeConstant(0.3, frames: 100, to: a)
    try writeConstant(0.4, frames: 100, to: b)

    let report = try AudioMixer.mixToFloatFile(a: a, b: b, outputURL: out)

    #expect(report.didNormalize == false)
    #expect(abs(report.peak - 0.7) < 0.0001)
    let samples = try readAll(out)
    #expect(samples.count == 100)
    #expect(abs(samples[0] - 0.7) < 0.0001)
}

@Test func normalizesWhenTheSumWouldClip() throws {
    let temp = try TempDirectory()
    let a = temp.url.appending(path: "a.caf")
    let b = temp.url.appending(path: "b.caf")
    let out = temp.url.appending(path: "out.caf")
    try writeConstant(0.8, frames: 50, to: a)
    try writeConstant(0.7, frames: 50, to: b)

    let report = try AudioMixer.mixToFloatFile(a: a, b: b, outputURL: out)

    #expect(report.didNormalize == true)
    #expect(abs(report.peak - 1.5) < 0.0001)
    #expect(abs(try readAll(out)[0] - 1.0) < 0.0001)
}

@Test func padsTheShorterSourceWithSilence() throws {
    let temp = try TempDirectory()
    let a = temp.url.appending(path: "a.caf")
    let b = temp.url.appending(path: "b.caf")
    let out = temp.url.appending(path: "out.caf")
    try writeConstant(0.5, frames: 10, to: a)
    try writeConstant(0.25, frames: 40, to: b)

    let report = try AudioMixer.mixToFloatFile(a: a, b: b, outputURL: out)

    #expect(report.frameCount == 40)
    let samples = try readAll(out)
    #expect(abs(samples[0] - 0.75) < 0.0001)   // both sources overlap here
    #expect(abs(samples[20] - 0.25) < 0.0001)  // only the longer source remains
}

@Test func handlesAnEmptySourceFile() throws {
    let temp = try TempDirectory()
    let a = temp.url.appending(path: "a.caf")
    let b = temp.url.appending(path: "b.caf")
    let out = temp.url.appending(path: "out.caf")
    try writeConstant(0.5, frames: 0, to: a)
    try writeConstant(0.5, frames: 20, to: b)

    let report = try AudioMixer.mixToFloatFile(a: a, b: b, outputURL: out)

    #expect(report.frameCount == 20)
    #expect(abs(try readAll(out)[0] - 0.5) < 0.0001)
}

@Test func mixProducesAPlayableM4AOfTheRightDuration() throws {
    let temp = try TempDirectory()
    let mic = temp.url.appending(path: "mic.caf")
    let system = temp.url.appending(path: "system.caf")
    let mixed = temp.url.appending(path: "mixed.m4a")
    try writeConstant(0.2, frames: 48_000, to: mic)     // 1 second at 48kHz
    try writeConstant(0.2, frames: 48_000, to: system)

    let report = try AudioMixer.mix(micURL: mic, systemURL: system, outputURL: mixed)

    #expect(report.frameCount == 48_000)
    #expect(FileManager.default.fileExists(atPath: mixed.path))
    let encoded = try AVAudioFile(forReading: mixed)
    // AAC pads slightly; assert the duration is about right rather than exact.
    let seconds = Double(encoded.length) / encoded.processingFormat.sampleRate
    #expect(abs(seconds - 1.0) < 0.1)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd MeetingCore && swift test`
Expected: FAIL — `cannot find 'AudioMixer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `MeetingCore/Sources/MeetingCore/AudioMixer.swift`:

```swift
import AVFoundation
import Foundation

public struct MixReport: Equatable, Sendable {
    /// Peak absolute sample value of the raw sum, before any normalization.
    public let peak: Float
    public let frameCount: AVAudioFramePosition
    public let didNormalize: Bool
}

public enum AudioMixerError: Error, Equatable {
    case cannotAllocateBuffer
    case noAudio
}

public enum AudioMixer {
    /// Mono 48 kHz float — lossless and trivially assertable in tests.
    public static let processingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    /// Sums two files into a lossless float file, scaling the result down if
    /// the sum would clip. The shorter file is padded with silence.
    ///
    /// This is the exact, testable core. `mix` wraps it to produce the `.m4a`.
    @discardableResult
    public static func mixToFloatFile(a: URL, b: URL, outputURL: URL) throws -> MixReport {
        let fileA = try AVAudioFile(forReading: a)
        let fileB = try AVAudioFile(forReading: b)
        let frames = max(fileA.length, fileB.length)
        guard frames > 0 else { throw AudioMixerError.noAudio }

        var summed = [Float](repeating: 0, count: Int(frames))
        for file in [fileA, fileB] {
            let count = Int(file.length)
            guard count > 0 else { continue }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(count)
            ) else { throw AudioMixerError.cannotAllocateBuffer }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { continue }
            for i in 0..<Int(buffer.frameLength) { summed[i] += channel[i] }
        }

        let peak = summed.reduce(Float(0)) { max($0, abs($1)) }
        let gain: Float = peak > 1.0 ? 1.0 / peak : 1.0
        if gain != 1.0 {
            for i in summed.indices { summed[i] *= gain }
        }

        let output = try AVAudioFile(
            forWriting: outputURL, settings: processingFormat.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(frames)
        ) else { throw AudioMixerError.cannotAllocateBuffer }
        outputBuffer.frameLength = AVAudioFrameCount(frames)
        summed.withUnsafeBufferPointer { source in
            outputBuffer.floatChannelData![0].update(
                from: source.baseAddress!, count: Int(frames))
        }
        try output.write(from: outputBuffer)

        return MixReport(peak: peak, frameCount: frames, didNormalize: gain != 1.0)
    }

    /// Mixes the two raw captures into an AAC `.m4a`. Pass 1 sums losslessly to
    /// a temporary file; pass 2 encodes. Neither input file is modified.
    @discardableResult
    public static func mix(micURL: URL, systemURL: URL, outputURL: URL) throws -> MixReport {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "mix-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let report = try mixToFloatFile(a: micURL, b: systemURL, outputURL: scratch)

        let source = try AVAudioFile(forReading: scratch)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: processingFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let destination = try AVAudioFile(forWriting: outputURL, settings: settings)

        let chunk: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: source.processingFormat, frameCapacity: chunk
        ) else { throw AudioMixerError.cannotAllocateBuffer }
        while source.framePosition < source.length {
            try source.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            try destination.write(from: buffer)
        }

        return report
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd MeetingCore && swift test`
Expected: PASS, 16 tests total.

- [ ] **Step 5: Commit**

```bash
git add MeetingCore/Sources/MeetingCore/AudioMixer.swift \
        MeetingCore/Tests/MeetingCoreTests/AudioMixerTests.swift
git commit -m "feat: add offline audio mixer with clip normalization"
```

---

### Task 4: Summary model and Claude request construction

**Files:**
- Create: `MeetingCore/Sources/MeetingCore/MeetingSummary.swift`
- Create: `MeetingCore/Sources/MeetingCore/Summarizer.swift`
- Create: `MeetingCore/Sources/MeetingCore/ClaudeSummarizer.swift`
- Test: `MeetingCore/Tests/MeetingCoreTests/ClaudeSummarizerRequestTests.swift`

**Interfaces:**
- Consumes: `Transcript` (Task 1)
- Produces:
  - `struct MeetingSummary { let title, summary: String; let decisions: [String]; let actionItems: [ActionItem]; let openQuestions: [String] }`, `struct MeetingSummary.ActionItem { let owner, task: String }`
  - `protocol Summarizer: Sendable { func summarize(_ transcript: Transcript) async throws -> MeetingSummary }`
  - `enum SummarizerError: Error, Equatable`
  - `struct ClaudeSummarizer: Summarizer` with `init(apiKey: String, session: URLSession = .shared, endpoint: URL = ClaudeSummarizer.defaultEndpoint)` and `func makeRequest(for: Transcript) throws -> URLRequest`

- [ ] **Step 1: Write the failing test**

Create `MeetingCore/Tests/MeetingCoreTests/ClaudeSummarizerRequestTests.swift`:

```swift
import Foundation
import Testing
@testable import MeetingCore

private func decodeBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let sampleTranscript = Transcript(segments: [
    TranscriptSegment(start: 0, end: 4, text: "We should cut billing from Q3."),
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd MeetingCore && swift test`
Expected: FAIL — `cannot find 'ClaudeSummarizer' in scope`.

- [ ] **Step 3: Write the summary model**

Create `MeetingCore/Sources/MeetingCore/MeetingSummary.swift`:

```swift
import Foundation

public struct MeetingSummary: Codable, Equatable, Sendable {
    public struct ActionItem: Codable, Equatable, Sendable {
        public let owner: String
        public let task: String

        public init(owner: String, task: String) {
            self.owner = owner
            self.task = task
        }
    }

    public let title: String
    public let summary: String
    public let decisions: [String]
    public let actionItems: [ActionItem]
    public let openQuestions: [String]

    private enum CodingKeys: String, CodingKey {
        case title, summary, decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }

    public init(
        title: String,
        summary: String,
        decisions: [String],
        actionItems: [ActionItem],
        openQuestions: [String]
    ) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }

    /// Rendered form written to `summary.md`.
    public var markdown: String {
        var lines = ["# \(title)", "", summary]
        if !decisions.isEmpty {
            lines += ["", "## Decisions"] + decisions.map { "- \($0)" }
        }
        if !actionItems.isEmpty {
            lines += ["", "## Action items"] + actionItems.map { "- **\($0.owner)**: \($0.task)" }
        }
        if !openQuestions.isEmpty {
            lines += ["", "## Open questions"] + openQuestions.map { "- \($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
```

- [ ] **Step 4: Write the protocol and error type**

Create `MeetingCore/Sources/MeetingCore/Summarizer.swift`:

```swift
import Foundation

public protocol Summarizer: Sendable {
    func summarize(_ transcript: Transcript) async throws -> MeetingSummary
}

public enum SummarizerError: Error, Equatable {
    case missingAPIKey
    case emptyTranscript
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    /// The model declined the request. Retrying the identical request will not help.
    case refused(category: String?)
    case httpError(status: Int)
    case malformedResponse(String)
}

extension SummarizerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Claude API key. Add one in Settings."
        case .emptyTranscript:
            return "The transcript is empty, so there is nothing to summarize."
        case .unauthorized:
            return "The Claude API rejected the key. Check it in Settings."
        case .rateLimited(let retryAfter):
            guard let retryAfter else { return "Rate limited by the Claude API." }
            return "Rate limited by the Claude API. Retry in \(Int(retryAfter))s."
        case .refused(let category):
            let suffix = category.map { " (\($0))" } ?? ""
            return "The model declined to summarize this meeting\(suffix)."
        case .httpError(let status):
            return "The Claude API returned HTTP \(status)."
        case .malformedResponse:
            return "The Claude API response could not be parsed."
        }
    }
}
```

- [ ] **Step 5: Write the request-building half of ClaudeSummarizer**

Create `MeetingCore/Sources/MeetingCore/ClaudeSummarizer.swift`. The `summarize` body is filled in by Task 5; it throws for now so the type conforms.

```swift
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

    static let responseSchema: [String: Any] = [
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
        // Implemented in Task 5.
        throw SummarizerError.malformedResponse("not implemented")
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd MeetingCore && swift test`
Expected: PASS, 23 tests total.

- [ ] **Step 7: Commit**

```bash
git add MeetingCore/Sources/MeetingCore/MeetingSummary.swift \
        MeetingCore/Sources/MeetingCore/Summarizer.swift \
        MeetingCore/Sources/MeetingCore/ClaudeSummarizer.swift \
        MeetingCore/Tests/MeetingCoreTests/ClaudeSummarizerRequestTests.swift
git commit -m "feat: add summary model and Claude request construction"
```

---

### Task 5: Claude streaming response and error handling

The stub and parsing approach below were prototyped and verified during design.

**Files:**
- Modify: `MeetingCore/Sources/MeetingCore/ClaudeSummarizer.swift` (replace the `summarize` stub)
- Create: `MeetingCore/Tests/MeetingCoreTests/Support/StubURLProtocol.swift`
- Test: `MeetingCore/Tests/MeetingCoreTests/ClaudeSummarizerStreamingTests.swift`

**Interfaces:**
- Consumes: `ClaudeSummarizer.makeRequest(for:)`, `SummarizerError`, `MeetingSummary` (Task 4)
- Produces: a working `ClaudeSummarizer.summarize(_:)`; test helper `StubURLProtocol.register(_:) -> URL` and `struct StubResponse { var status: Int; var headers: [String: String]; var chunks: [String] }`

- [ ] **Step 1: Write the parallel-safe HTTP stub**

Registering each fixture against a unique URL is what makes this safe under Swift Testing's parallel execution. Do not replace it with shared static fixture state.

Create `MeetingCore/Tests/MeetingCoreTests/Support/StubURLProtocol.swift`:

```swift
import Foundation

struct StubResponse: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    /// Delivered as separate `didLoad` calls, so tests exercise chunk splitting.
    var chunks: [String] = []
}

/// Each test registers its response against a unique URL, so concurrently
/// running tests never share fixture state.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var table: [URL: StubResponse] = [:]

    static func register(_ response: StubResponse) -> URL {
        let url = URL(string: "https://stub.test/\(UUID().uuidString)")!
        lock.lock()
        table[url] = response
        lock.unlock()
        return url
    }

    private static func stub(for url: URL) -> StubResponse? {
        lock.lock()
        defer { lock.unlock() }
        return table[url]
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.stub(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: stub.status,
            httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: Data(chunk.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

- [ ] **Step 2: Write the failing test**

Create `MeetingCore/Tests/MeetingCoreTests/ClaudeSummarizerStreamingTests.swift`:

```swift
import Foundation
import Testing
@testable import MeetingCore

private let transcript = Transcript(segments: [
    TranscriptSegment(start: 0, end: 4, text: "We should cut billing from Q3."),
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
    let url = StubURLProtocol.register(.init(chunks: [
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
    let url = StubURLProtocol.register(.init(chunks: [
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
    let url = StubURLProtocol.register(.init(chunks: [
        textDelta("{\"title\": \"unterminated"),
        messageDelta(stopReason: "end_turn"),
    ]))

    await #expect(throws: SummarizerError.self) {
        _ = try await summarizer(for: url).summarize(transcript)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd MeetingCore && swift test`
Expected: FAIL — the tests reach the `summarize` stub and get `malformedResponse("not implemented")`.

- [ ] **Step 4: Replace the `summarize` stub with the streaming implementation**

In `MeetingCore/Sources/MeetingCore/ClaudeSummarizer.swift`, replace the placeholder `summarize` with:

```swift
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
            let retryAfter = http.value(forHTTPHeaderField: "retry-after")
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
                   let chunk = delta["text"] as? String {
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd MeetingCore && swift test`
Expected: PASS, 30 tests total.

- [ ] **Step 6: Commit**

```bash
git add MeetingCore/Sources/MeetingCore/ClaudeSummarizer.swift \
        MeetingCore/Tests/MeetingCoreTests/ClaudeSummarizerStreamingTests.swift \
        MeetingCore/Tests/MeetingCoreTests/Support/StubURLProtocol.swift
git commit -m "feat: stream and parse Claude summary responses"
```

---

### Task 6: Transcriber protocol and on-device engine

`SpeechTranscriberEngine` is **not** unit tested — it needs an installed speech model and produces nondeterministic output. The protocol and error type are what the pipeline is tested against; the engine gets a build check and a manual verification step.

**Files:**
- Create: `MeetingCore/Sources/MeetingCore/Transcriber.swift`
- Create: `MeetingCore/Sources/MeetingCore/SpeechTranscriberEngine.swift`
- Create: `MeetingCore/Tests/MeetingCoreTests/Support/Fakes.swift`

**Interfaces:**
- Consumes: `Transcript`, `TranscriptSegment` (Task 1)
- Produces:
  - `protocol Transcriber: Sendable { func transcribe(audioFileAt url: URL) async throws -> Transcript }`
  - `enum TranscriberError: Error, Equatable`
  - `struct SpeechTranscriberEngine: Transcriber` with `init(locale: Locale = .current)` and `static func ensureModelInstalled(locale:progress:) async throws`
  - Test fakes `FakeTranscriber` and `FakeSummarizer` (used by Task 7)

- [ ] **Step 1: Write the protocol and error type**

Create `MeetingCore/Sources/MeetingCore/Transcriber.swift`:

```swift
import Foundation

public protocol Transcriber: Sendable {
    func transcribe(audioFileAt url: URL) async throws -> Transcript
}

public enum TranscriberError: Error, Equatable {
    case localeUnsupported(String)
    case modelUnavailable
    case audioUnreadable(String)
    case analysisFailed(String)
}

extension TranscriberError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .localeUnsupported(let identifier):
            return "On-device transcription does not support \(identifier)."
        case .modelUnavailable:
            return "The speech model is not installed and could not be downloaded."
        case .audioUnreadable(let detail):
            return "The mixed audio file could not be read: \(detail)"
        case .analysisFailed(let detail):
            return "Transcription failed: \(detail)"
        }
    }
}
```

- [ ] **Step 2: Write the test fakes**

Create `MeetingCore/Tests/MeetingCoreTests/Support/Fakes.swift`:

```swift
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
        TranscriptSegment(start: 0, end: 4, text: "We should cut billing from Q3."),
    ])
}
```

- [ ] **Step 3: Write the on-device engine**

Create `MeetingCore/Sources/MeetingCore/SpeechTranscriberEngine.swift`. The API shapes here (`SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)`, `AssetInventory.assetInstallationRequest(supporting:)`, `SpeechAnalyzer.analyzeSequence(from:)`, `Result.range` / `Result.text`) were read from the macOS 26.5 SDK interface during design.

```swift
import AVFoundation
import Foundation
import Speech

public struct SpeechTranscriberEngine: Transcriber {
    let locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Final results only, with time ranges attached. No volatile/partial results —
    /// this runs over a finished file, so there is nothing to preview.
    private static func makeModule(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    private static func resolveLocale(_ requested: Locale) async throws -> Locale {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        else { throw TranscriberError.localeUnsupported(requested.identifier) }
        return supported
    }

    /// Downloads the speech model if it is not already installed. Call this at
    /// launch so the download is a visible one-time step rather than an
    /// apparently-hung first recording.
    public static func ensureModelInstalled(
        locale requested: Locale = .current,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        let locale = try await resolveLocale(requested)
        let module = makeModule(locale: locale)
        guard await AssetInventory.status(forModules: [module]) != .installed else { return }
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [module]
        ) else { throw TranscriberError.modelUnavailable }
        progress?(request.progress)
        try await request.downloadAndInstall()
    }

    public func transcribe(audioFileAt url: URL) async throws -> Transcript {
        let resolvedLocale = try await Self.resolveLocale(locale)
        let module = Self.makeModule(locale: resolvedLocale)

        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw TranscriberError.modelUnavailable
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriberError.audioUnreadable(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: [module])

        // Collect results concurrently with the analysis — `results` is an async
        // sequence that finishes when the analyzer finalizes.
        let collector = Task { () -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in module.results {
                let text = String(result.text.characters)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                segments.append(TranscriptSegment(
                    start: result.range.start.seconds,
                    end: result.range.end.seconds,
                    text: text
                ))
            }
            return segments
        }

        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw TranscriberError.analysisFailed(error.localizedDescription)
        }

        do {
            return Transcript(segments: try await collector.value)
        } catch {
            throw TranscriberError.analysisFailed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Verify the package builds and existing tests still pass**

Run: `cd MeetingCore && swift build && swift test`
Expected: build succeeds; 30 tests still pass. If the compiler rejects a `Speech` symbol, read the current signature before guessing:

```bash
SDK=$(xcrun --show-sdk-path --sdk macosx)
grep -n "SpeechTranscriber\|AssetInventory" \
  "$SDK/System/Library/Frameworks/Speech.framework/Versions/A/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface"
```

- [ ] **Step 5: Commit**

```bash
git add MeetingCore/Sources/MeetingCore/Transcriber.swift \
        MeetingCore/Sources/MeetingCore/SpeechTranscriberEngine.swift \
        MeetingCore/Tests/MeetingCoreTests/Support/Fakes.swift
git commit -m "feat: add transcriber protocol and on-device speech engine"
```

---

### Task 7: Pipeline coordinator

**Files:**
- Create: `MeetingCore/Sources/MeetingCore/PipelineCoordinator.swift`
- Test: `MeetingCore/Tests/MeetingCoreTests/PipelineCoordinatorTests.swift`

**Interfaces:**
- Consumes: `MeetingStore`, `MeetingMetadata`, `MeetingStage` (Task 2); `AudioMixer` (Task 3); `Summarizer` (Task 4); `Transcriber` (Task 6)
- Produces: `actor PipelineCoordinator` with `init(store:transcriber:summarizer:onStageChange:)` and `@discardableResult func process(meetingID: UUID) async throws -> MeetingMetadata`. It `throws` only if the meeting's metadata cannot be read at all; a *stage* failure is returned as `.failed` metadata, not thrown, so the UI can offer a retry.

- [ ] **Step 1: Write the failing test**

Create `MeetingCore/Tests/MeetingCoreTests/PipelineCoordinatorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd MeetingCore && swift test`
Expected: FAIL — `cannot find 'PipelineCoordinator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `MeetingCore/Sources/MeetingCore/PipelineCoordinator.swift`:

```swift
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
    /// than throwing: a failed stage is a recorded state, not an exception, so
    /// the UI can offer a retry.
    @discardableResult
    public func process(meetingID id: UUID) async throws -> MeetingMetadata {
        var metadata = try store.read(id: id)
        let resumeFrom = metadata.stage == .failed ? (metadata.failedStage ?? .mixing) : .mixing

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
            metadata.failureReason = (error as? LocalizedError)?.errorDescription
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd MeetingCore && swift test`
Expected: PASS, 35 tests total.

- [ ] **Step 5: Commit**

```bash
git add MeetingCore/Sources/MeetingCore/PipelineCoordinator.swift \
        MeetingCore/Tests/MeetingCoreTests/PipelineCoordinatorTests.swift
git commit -m "feat: add resumable pipeline coordinator"
```

---

### Task 8: Xcode app shell and permission pre-flight

This task has manual GUI steps — no project generator (`xcodegen`, `tuist`) is installed, and adding one is more setup than creating the project once by hand.

**Files:**
- Create: `MeetingRecorder/` Xcode project (via Xcode)
- Create: `MeetingRecorder/PermissionChecker.swift`
- Modify: `MeetingRecorder/Info.plist`

**Interfaces:**
- Consumes: `MeetingCore` package
- Produces: `enum PermissionStatus { granted, denied, undetermined }`; `enum PermissionChecker` with `static func microphoneStatus() -> PermissionStatus`, `static func requestMicrophone() async -> Bool`, `static func screenRecordingStatus() async -> PermissionStatus`, `static func openSettings(for:)`

- [ ] **Step 1: Create the Xcode project**

In Xcode: **File → New → Project → macOS → App**.

- Product Name: `MeetingRecorder`
- Interface: **SwiftUI**, Language: **Swift**, Testing System: **None** (tests live in the package)
- Storage: **None**
- Save into the repository root, so the project sits at `MeetingRecorder/`.

- [ ] **Step 2: Turn off the App Sandbox**

Select the project → **MeetingRecorder** target → **Signing & Capabilities**. If **App Sandbox** is listed, hover it and click the **×** to remove it.

This is required: a sandboxed app cannot write to `~/Library/Application Support/MeetingRecorder` outside its container, and the spec places recordings there. The design explicitly chose an unsandboxed personal tool.

- [ ] **Step 3: Set the deployment target and add the package**

- Target → **General** → **Minimum Deployments** → macOS **26.0**.
- **File → Add Package Dependencies… → Add Local…** → select the `MeetingCore` folder → add the `MeetingCore` library to the `MeetingRecorder` target.

- [ ] **Step 4: Add the usage descriptions**

Target → **Info** tab, add two rows:

| Key | Value |
|---|---|
| `NSMicrophoneUsageDescription` | `Meeting Recorder records your microphone so your side of the meeting is captured.` |
| `NSSpeechRecognitionUsageDescription` | `Meeting Recorder transcribes recordings on this Mac. Audio is not sent anywhere for transcription.` |

Screen Recording has no usage-description key — macOS prompts on the first ScreenCaptureKit call.

- [ ] **Step 5: Verify the app builds and links the package**

Replace the body of `MeetingRecorder/ContentView.swift` with a temporary check:

```swift
import MeetingCore
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Meetings root: \(MeetingStore.defaultRoot.path)")
            .padding()
    }
}
```

Build and run (⌘R). Expected: a window showing a path ending in `MeetingRecorder/Meetings`. This proves the package is linked.

- [ ] **Step 6: Write the permission checker**

Create `MeetingRecorder/PermissionChecker.swift`:

```swift
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum PermissionStatus: Equatable {
    case granted
    case denied
    case undetermined
}

enum PermissionKind: Equatable {
    case microphone
    case screenRecording

    var settingsURL: URL {
        switch self {
        case .microphone:
            return URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .screenRecording:
            return URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }

    var explanation: String {
        switch self {
        case .microphone:
            return "Meeting Recorder needs microphone access to capture your side of the meeting."
        case .screenRecording:
            return """
                Meeting Recorder needs Screen Recording access to capture the audio of \
                other participants. It records audio only — no video is saved.
                """
        }
    }
}

enum PermissionChecker {
    static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// There is no direct query for ScreenCaptureKit authorization, so this
    /// probes by asking for shareable content — the same call that triggers the
    /// system prompt.
    static func screenRecordingStatus() async -> PermissionStatus {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            return .granted
        } catch {
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
    }

    static func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}
```

Add `import AppKit` if `NSWorkspace` does not resolve.

- [ ] **Step 7: Verify it builds**

Build (⌘B). Expected: success, no warnings about missing frameworks.

- [ ] **Step 8: Commit**

```bash
git add MeetingRecorder
git commit -m "feat: add unsandboxed Xcode app shell and permission pre-flight"
```

---

### Task 9: Recording engine

**Files:**
- Create: `MeetingRecorder/CMSampleBuffer+PCM.swift`
- Create: `MeetingRecorder/RecordingEngine.swift`
- Create: `MeetingRecorder/docs/manual-smoke-test.md`

**Interfaces:**
- Consumes: `MeetingStore` (Task 2)
- Produces: `@MainActor final class RecordingEngine` with `init(store:)`, `func start(meetingID: UUID) async throws`, `func stop() async -> TimeInterval`, `var isRecording: Bool`, `var elapsed: TimeInterval`

- [ ] **Step 1: Write the sample-buffer conversion helper**

Create `MeetingRecorder/CMSampleBuffer+PCM.swift`:

```swift
import AVFoundation
import CoreMedia

extension CMSampleBuffer {
    /// Wraps this buffer's audio as an `AVAudioPCMBuffer` without copying samples.
    /// Returns nil for non-audio buffers (the discarded screen frames).
    func asPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd)
        else { return nil }

        return try? withAudioBufferList { audioBufferList, _ in
            AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
}
```

- [ ] **Step 2: Write the recording engine**

Create `MeetingRecorder/RecordingEngine.swift`:

```swift
import AVFoundation
import Foundation
import MeetingCore
import ScreenCaptureKit

enum RecordingError: LocalizedError {
    case noDisplayAvailable
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display is available to capture audio from."
        case .alreadyRecording:
            return "A recording is already in progress."
        }
    }
}

/// Owns the SCStream and writes each audio source straight to its own file.
/// Deliberately does no mixing — see the design doc. The only job here is to
/// not lose audio.
/// Plain class, not `ObservableObject`: `AppModel` owns all published state and
/// polls `elapsed`. Adding a second observation mechanism here would give the
/// views two sources of truth for the same value.
@MainActor
final class RecordingEngine: NSObject {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0

    private let store: MeetingStore
    private var stream: SCStream?
    private var writers: [SCStreamOutputType: AudioFileWriter] = [:]
    private var startedAt: Date?
    private var ticker: Timer?

    private let micQueue = DispatchQueue(label: "recording.mic")
    private let systemQueue = DispatchQueue(label: "recording.system")
    private let screenQueue = DispatchQueue(label: "recording.screen")

    init(store: MeetingStore) {
        self.store = store
        super.init()
    }

    func start(meetingID: UUID) async throws {
        guard !isRecording else { throw RecordingError.alreadyRecording }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw RecordingError.noDisplayAvailable
        }

        let configuration = SCStreamConfiguration()
        // ScreenCaptureKit requires a video configuration even for audio-only
        // capture. 2x2 at 1fps is the cheapest legal stream; frames are dropped.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        writers = [
            .audio: AudioFileWriter(url: store.systemURL(for: meetingID)),
            .microphone: AudioFileWriter(url: store.micURL(for: meetingID)),
        ]

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)

        try await stream.startCapture()

        self.stream = stream
        startedAt = Date()
        isRecording = true
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    /// Stops capture and returns the recorded duration. Never throws — a failure
    /// to stop cleanly must not lose what was already written.
    @discardableResult
    func stop() async -> TimeInterval {
        guard isRecording else { return 0 }
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0

        try? await stream?.stopCapture()
        stream = nil
        for writer in writers.values { writer.close() }
        writers.removeAll()

        ticker?.invalidate()
        ticker = nil
        startedAt = nil
        elapsed = 0
        isRecording = false
        return duration
    }
}

extension RecordingEngine: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio || type == .microphone else { return }  // drop screen frames
        guard sampleBuffer.isValid, let pcm = sampleBuffer.asPCMBuffer() else { return }
        Task { @MainActor [weak self] in
            self?.writers[type]?.write(pcm)
        }
    }
}

/// Lazily creates the output file on the first buffer, so its format matches
/// whatever the system actually delivers.
private final class AudioFileWriter {
    private let url: URL
    private var file: AVAudioFile?

    init(url: URL) { self.url = url }

    func write(_ buffer: AVAudioPCMBuffer) {
        do {
            if file == nil {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: buffer.format.settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved)
            }
            try file?.write(from: buffer)
        } catch {
            NSLog("RecordingEngine: failed to write %@: %@",
                  url.lastPathComponent, error.localizedDescription)
        }
    }

    func close() { file = nil }
}
```

- [ ] **Step 3: Write the manual smoke-test checklist**

Create `MeetingRecorder/docs/manual-smoke-test.md`:

```markdown
# RecordingEngine manual smoke test

`RecordingEngine` is not unit tested — it needs real TCC permission and real
system audio, and the failure modes that matter (permission denial, device
changes, silent empty files) are exactly the ones a mock cannot reproduce.
Run this checklist after changing it.

## Setup
Play audio from another app (a YouTube video works) and be ready to speak.

## Steps
1. Launch the app. Start a recording.
   - [ ] macOS prompts for Microphone access on first run.
   - [ ] macOS prompts for Screen Recording access on first run.
   - [ ] The menu bar icon turns red and the elapsed timer counts up.
2. Speak for ~5 seconds while the other app plays audio.
3. Stop the recording.
4. Open `~/Library/Application Support/MeetingRecorder/Meetings/<newest>/`.
   - [ ] `mic.caf` exists and is larger than 10 KB.
   - [ ] `system.caf` exists and is larger than 10 KB.
   - [ ] Playing `mic.caf` in QuickTime plays back your voice.
   - [ ] Playing `system.caf` plays back the other app's audio, not your voice.
   - [ ] `mixed.m4a` contains both.

## Failure cases
5. Deny Screen Recording in System Settings, relaunch, try to record.
   - [ ] An explanatory sheet appears with a working button to System Settings.
   - [ ] The app does not crash and no empty meeting folder is left behind.
6. Start a recording, then stop it after ~1 second.
   - [ ] Both files still exist and are non-empty.
```

- [ ] **Step 4: Build and run the smoke test**

Build (⌘B), then run the checklist in `MeetingRecorder/docs/manual-smoke-test.md` end to end. Record any step that fails; do not proceed with failures outstanding.

- [ ] **Step 5: Commit**

```bash
git add MeetingRecorder/RecordingEngine.swift \
        MeetingRecorder/CMSampleBuffer+PCM.swift \
        MeetingRecorder/docs/manual-smoke-test.md
git commit -m "feat: capture microphone and system audio to separate files"
```

---

### Task 10: SwiftData library index

**Files:**
- Create: `MeetingRecorder/MeetingRecord.swift`
- Create: `MeetingRecorder/MeetingLibrary.swift`

**Interfaces:**
- Consumes: `MeetingStore`, `MeetingMetadata` (Task 2)
- Produces: `@Model final class MeetingRecord`; `@MainActor final class MeetingLibrary` with `init(store:modelContext:)`, `func rebuildFromDisk() throws`, `func upsert(_ metadata: MeetingMetadata) throws`, `func delete(id: UUID) throws`, `var meetings: [MeetingRecord]`

- [ ] **Step 1: Write the model**

Create `MeetingRecorder/MeetingRecord.swift`:

```swift
import Foundation
import MeetingCore
import SwiftData

@Model
final class MeetingRecord {
    #Unique<MeetingRecord>([\.id])

    var id: UUID
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
```

- [ ] **Step 2: Write the library**

Create `MeetingRecorder/MeetingLibrary.swift`:

```swift
import Foundation
import MeetingCore
import Observation
import SwiftData

/// Keeps the SwiftData index in step with what is actually on disk.
///
/// Per the design doc, meeting folders are the durable artifact and this index
/// is a convenience: on any disagreement, disk wins and the index is rebuilt.
///
/// `meetings` is a *stored* property refreshed after every mutation, not a
/// computed fetch. `@Observable` only tracks stored properties, so a computed
/// `context.fetch(...)` would never notify SwiftUI and the list would sit stale
/// while a meeting moved through the pipeline.
@MainActor
@Observable
final class MeetingLibrary {
    private(set) var meetings: [MeetingRecord] = []

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let context: ModelContext

    init(store: MeetingStore, modelContext: ModelContext) {
        self.store = store
        self.context = modelContext
        refresh()
    }

    /// Reconciles the index against disk: adds missing meetings, refreshes
    /// changed ones, and drops rows whose folder no longer exists.
    func rebuildFromDisk() throws {
        let onDisk = try store.allMeetings()
        let byID = Dictionary(uniqueKeysWithValues: onDisk.map { ($0.id, $0) })

        for record in fetchAll() {
            if let metadata = byID[record.id] {
                record.apply(metadata)
            } else {
                context.delete(record)
            }
        }

        let indexed = Set(fetchAll().map(\.id))
        for metadata in onDisk where !indexed.contains(metadata.id) {
            context.insert(MeetingRecord(metadata: metadata))
        }

        try context.save()
        refresh()
    }

    func upsert(_ metadata: MeetingMetadata) throws {
        if let existing = fetchAll().first(where: { $0.id == metadata.id }) {
            existing.apply(metadata)
        } else {
            context.insert(MeetingRecord(metadata: metadata))
        }
        try context.save()
        refresh()
    }

    /// Deletes the folder first — the folder is the source of truth, so if the
    /// folder delete fails the index row must survive to reflect reality.
    func delete(id: UUID) throws {
        try store.delete(id: id)
        if let record = fetchAll().first(where: { $0.id == id }) {
            context.delete(record)
        }
        try context.save()
        refresh()
    }

    private func fetchAll() -> [MeetingRecord] {
        let descriptor = FetchDescriptor<MeetingRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private func refresh() {
        meetings = fetchAll()
    }
}
```

- [ ] **Step 3: Verify it builds**

Build (⌘B). Expected: success. If `#Unique` is unavailable, replace it with `@Attribute(.unique) var id: UUID`.

- [ ] **Step 4: Commit**

```bash
git add MeetingRecorder/MeetingRecord.swift MeetingRecorder/MeetingLibrary.swift
git commit -m "feat: add SwiftData meeting index rebuilt from disk"
```

---

### Task 11: Keychain storage and app model

**Files:**
- Create: `MeetingRecorder/KeychainStore.swift`
- Create: `MeetingRecorder/AppModel.swift`

**Interfaces:**
- Consumes: `RecordingEngine` (Task 9); `MeetingLibrary` (Task 10); `PipelineCoordinator`, `MeetingStore`, `ClaudeSummarizer`, `SpeechTranscriberEngine` (Tasks 2–7)
- Produces: `enum KeychainStore` with `static func readAPIKey() -> String?`, `static func writeAPIKey(_:) throws`, `static func deleteAPIKey()`; `@MainActor @Observable final class AppModel` with `func toggleRecording() async`, `func retry(meetingID: UUID) async`, `func deleteMeeting(id: UUID)`, `var isRecording: Bool`, `var elapsed: TimeInterval`, `var permissionPrompt: PermissionKind?`, `var errorMessage: String?`

- [ ] **Step 1: Write the Keychain wrapper**

Create `MeetingRecorder/KeychainStore.swift`:

```swift
import Foundation
import Security

/// The Claude API key lives here and nowhere else. It is never written to
/// meta.json, summary.md, or any log.
enum KeychainStore {
    private static let service = "com.meetingrecorder.claude"
    private static let account = "api-key"

    static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    static func writeAPIKey(_ key: String) throws {
        deleteAPIKey()
        guard !key.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 2: Write the app model**

Create `MeetingRecorder/AppModel.swift`:

```swift
import Foundation
import MeetingCore
import Observation
import SwiftData

@MainActor
@Observable
final class AppModel {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var isPreparingModel = false
    var permissionPrompt: PermissionKind?
    var errorMessage: String?

    let store: MeetingStore
    let library: MeetingLibrary
    private let engine: RecordingEngine
    private var currentMeetingID: UUID?
    private var tickTask: Task<Void, Never>?

    init(store: MeetingStore = MeetingStore(root: .defaultRootCreatingIfNeeded()),
         modelContext: ModelContext) {
        self.store = store
        self.engine = RecordingEngine(store: store)
        self.library = MeetingLibrary(store: store, modelContext: modelContext)
    }

    func onLaunch() async {
        try? library.rebuildFromDisk()
        isPreparingModel = true
        do {
            try await SpeechTranscriberEngine.ensureModelInstalled()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        isPreparingModel = false
    }

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        if PermissionChecker.microphoneStatus() != .granted,
           await PermissionChecker.requestMicrophone() == false {
            permissionPrompt = .microphone
            return
        }
        if await PermissionChecker.screenRecordingStatus() != .granted {
            permissionPrompt = .screenRecording
            return
        }

        let id = UUID()
        do {
            let metadata = try store.createMeeting(id: id, date: .now)
            try library.upsert(metadata)
            try await engine.start(meetingID: id)
            currentMeetingID = id
            isRecording = true
            startTicking()
        } catch {
            // Do not leave an empty folder behind for a recording that never began.
            try? store.delete(id: id)
            try? library.rebuildFromDisk()
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func stopRecording() async {
        guard let id = currentMeetingID else { return }
        let duration = await engine.stop()
        stopTicking()
        isRecording = false
        currentMeetingID = nil

        if var metadata = try? store.read(id: id) {
            metadata.duration = duration
            try? store.write(metadata)
            try? library.upsert(metadata)
        }
        await runPipeline(meetingID: id)
    }

    func retry(meetingID id: UUID) async {
        await runPipeline(meetingID: id)
    }

    func deleteMeeting(id: UUID) {
        do {
            try library.delete(id: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runPipeline(meetingID id: UUID) async {
        guard let apiKey = KeychainStore.readAPIKey() else {
            var metadata = (try? store.read(id: id)) ?? MeetingMetadata(
                id: id, title: "", date: .now)
            metadata.stage = .failed
            metadata.failedStage = .summarizing
            metadata.failureReason = SummarizerError.missingAPIKey.errorDescription
            try? store.write(metadata)
            try? library.upsert(metadata)
            errorMessage = SummarizerError.missingAPIKey.errorDescription
            return
        }

        let library = self.library
        let coordinator = PipelineCoordinator(
            store: store,
            transcriber: SpeechTranscriberEngine(),
            summarizer: ClaudeSummarizer(apiKey: apiKey),
            onStageChange: { metadata in
                Task { @MainActor in try? library.upsert(metadata) }
            }
        )
        do {
            let final = try await coordinator.process(meetingID: id)
            try? library.upsert(final)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.elapsed = self.engine.elapsed
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
        elapsed = 0
    }
}

extension URL {
    static func defaultRootCreatingIfNeeded() -> URL {
        let root = MeetingStore.defaultRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
```

- [ ] **Step 3: Verify it builds**

Build (⌘B). Expected: success.

- [ ] **Step 4: Commit**

```bash
git add MeetingRecorder/KeychainStore.swift MeetingRecorder/AppModel.swift
git commit -m "feat: add keychain key storage and app model wiring the pipeline"
```

---

### Task 12: Menu bar and main window

**Files:**
- Create: `MeetingRecorder/Views/RecordButton.swift`
- Create: `MeetingRecorder/Views/MeetingListView.swift`
- Modify: `MeetingRecorder/MeetingRecorderApp.swift`
- Delete: `MeetingRecorder/ContentView.swift`

**Interfaces:**
- Consumes: `AppModel` (Task 11); `MeetingRecord` (Task 10)
- Produces: `struct RecordButton: View`; `struct MeetingListView: View`; a `MenuBarExtra` plus main `Window` scene

- [ ] **Step 1: Write the record button**

Create `MeetingRecorder/Views/RecordButton.swift`:

```swift
import SwiftUI

struct RecordButton: View {
    let isRecording: Bool
    let elapsed: TimeInterval
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 120, height: 120)
                        .shadow(radius: isRecording ? 12 : 4)
                    if isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white)
                            .frame(width: 40, height: 40)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")

            Text(isRecording ? Self.format(elapsed) : "Ready")
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(isRecording ? .primary : .secondary)
                .contentTransition(.numericText())
        }
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
```

- [ ] **Step 2: Write the meeting list**

Create `MeetingRecorder/Views/MeetingListView.swift`:

```swift
import MeetingCore
import SwiftUI

struct MeetingListView: View {
    let meetings: [MeetingRecord]
    @Binding var selection: UUID?
    let onDelete: (UUID) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(meetings) { meeting in
                MeetingRow(meeting: meeting)
                    .tag(meeting.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { onDelete(meeting.id) }
                    }
            }
        }
        .overlay {
            if meetings.isEmpty {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "waveform",
                    description: Text("Press the red button to record your first meeting.")
                )
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: MeetingRecord

    var body: some View {
        HStack(spacing: 10) {
            StageIndicator(stage: meeting.stage)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).lineLimit(1)
                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if meeting.duration > 0 {
                Text(RecordButton.format(meeting.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct StageIndicator: View {
    let stage: MeetingStage

    var body: some View {
        switch stage {
        case .complete:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .recording:
            Image(systemName: "record.circle").foregroundStyle(.red)
        default:
            ProgressView().controlSize(.small)
        }
    }
}
```

- [ ] **Step 3: Rewrite the app entry point**

Replace `MeetingRecorder/MeetingRecorderApp.swift` with:

```swift
import MeetingCore
import SwiftData
import SwiftUI

@main
struct MeetingRecorderApp: App {
    private let container: ModelContainer
    @State private var model: AppModel

    init() {
        let container = try! ModelContainer(for: MeetingRecord.self)
        self.container = container
        _model = State(initialValue: AppModel(modelContext: container.mainContext))
    }

    var body: some Scene {
        Window("Meeting Recorder", id: "main") {
            MainView(model: model)
                .task { await model.onLaunch() }
        }
        .modelContainer(container)
        .defaultSize(width: 820, height: 560)

        MenuBarExtra {
            Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                Task { await model.toggleRecording() }
            }
            Divider()
            Button("Open Meeting Recorder") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "record.circle")
                .foregroundStyle(model.isRecording ? .red : .primary)
        }

        Settings {
            SettingsView()
        }
    }
}

struct MainView: View {
    @Bindable var model: AppModel
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                RecordButton(
                    isRecording: model.isRecording,
                    elapsed: model.elapsed,
                    action: { Task { await model.toggleRecording() } }
                )
                .padding(.vertical, 24)
                Divider()
                MeetingListView(
                    meetings: model.library.meetings,
                    selection: $selection,
                    onDelete: { model.deleteMeeting(id: $0) }
                )
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 300)
        } detail: {
            if let selection, let meeting = model.library.meetings.first(where: {
                $0.id == selection
            }) {
                MeetingDetailView(meeting: meeting, model: model)
            } else {
                ContentUnavailableView(
                    "No meeting selected", systemImage: "doc.text")
            }
        }
        .alert(
            "Permission needed",
            isPresented: Binding(
                get: { model.permissionPrompt != nil },
                set: { if !$0 { model.permissionPrompt = nil } }
            ),
            presenting: model.permissionPrompt
        ) { kind in
            Button("Open System Settings") { PermissionChecker.openSettings(for: kind) }
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            Text(kind.explanation)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
```

- [ ] **Step 4: Delete the placeholder view**

```bash
rm MeetingRecorder/ContentView.swift
```

Also remove it from the target in Xcode if it is still referenced.

- [ ] **Step 5: Verify the app runs**

Build and run (⌘R). Expected:
- A window with a large red button and an empty-state message.
- A record-circle icon in the menu bar.
- Clicking the red button prompts for permissions.

Task 13 supplies `MeetingDetailView` and `SettingsView`; until then the build will fail on those two symbols. Create empty placeholder files if you want to run before Task 13:

```swift
// MeetingRecorder/Views/MeetingDetailView.swift
import SwiftUI
struct MeetingDetailView: View {
    let meeting: MeetingRecord
    @Bindable var model: AppModel
    var body: some View { Text(meeting.title) }
}
```
```swift
// MeetingRecorder/Views/SettingsView.swift
import SwiftUI
struct SettingsView: View { var body: some View { Text("Settings") } }
```

- [ ] **Step 6: Commit**

```bash
git add MeetingRecorder/Views MeetingRecorder/MeetingRecorderApp.swift
git rm --cached MeetingRecorder/ContentView.swift 2>/dev/null || true
git commit -m "feat: add menu bar, record button, and meeting list"
```

---

### Task 13: Detail view, settings, and retry

**Files:**
- Modify: `MeetingRecorder/Views/MeetingDetailView.swift`
- Modify: `MeetingRecorder/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `AppModel`, `KeychainStore` (Task 11); `MeetingRecord` (Task 10); `MeetingStore`, `Transcript`, `MeetingStage` (Tasks 1–2)
- Produces: final `MeetingDetailView` and `SettingsView`

- [ ] **Step 1: Write the detail view**

Replace `MeetingRecorder/Views/MeetingDetailView.swift`:

```swift
import Foundation
import MeetingCore
import SwiftUI

struct MeetingDetailView: View {
    let meeting: MeetingRecord
    @Bindable var model: AppModel

    @State private var summaryMarkdown: String = ""
    @State private var transcript: Transcript?
    @State private var isRetrying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if meeting.stage == .failed {
                    failureBanner
                }

                if !summaryMarkdown.isEmpty {
                    section("Summary") {
                        Text(LocalizedStringKey(summaryMarkdown))
                            .textSelection(.enabled)
                    }
                }

                if let transcript, !transcript.segments.isEmpty {
                    section("Transcript") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(transcript.segments.enumerated()), id: \.offset) {
                                _, segment in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(RecordButton.format(segment.start))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 68, alignment: .leading)
                                    Text(segment.text).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: meeting.id) { load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title).font(.largeTitle.bold()).textSelection(.enabled)
            HStack(spacing: 8) {
                Text(meeting.date.formatted(date: .complete, time: .shortened))
                if meeting.duration > 0 {
                    Text("·")
                    Text(RecordButton.format(meeting.duration))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var failureBanner: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.failureReason ?? "This meeting did not finish processing.")
                    Text("Your audio is safe. Nothing has been deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isRetrying ? "Retrying…" : "Retry") {
                    isRetrying = true
                    Task {
                        await model.retry(meetingID: meeting.id)
                        isRetrying = false
                        load()
                    }
                }
                .disabled(isRetrying)
            }
            .padding(6)
        }
    }

    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func load() {
        let store = model.store
        summaryMarkdown = (try? String(contentsOf: store.summaryURL(for: meeting.id),
                                       encoding: .utf8)) ?? ""
        transcript = (try? Data(contentsOf: store.transcriptURL(for: meeting.id)))
            .flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
    }
}
```

- [ ] **Step 2: Write the settings view**

Replace `MeetingRecorder/Views/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("Claude API") {
                SecureField("API key", text: $apiKey)
                    .textContentType(.password)
                HStack {
                    Button("Save") {
                        try? KeychainStore.writeAPIKey(
                            apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        saved = true
                    }
                    if saved {
                        Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
                Text("""
                    Used only to summarize transcripts. Stored in your Keychain. \
                    Recording and transcription happen entirely on this Mac.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .onAppear { apiKey = KeychainStore.readAPIKey() ?? "" }
        .onChange(of: apiKey) { saved = false }
    }
}
```

- [ ] **Step 3: Run the full end-to-end check**

Build and run (⌘R), then:

- [ ] Open Settings (⌘,), paste a Claude API key, press Save. Confirm "Saved to Keychain".
- [ ] Play audio in another app, press the red button, speak for ~15 seconds, press stop.
- [ ] The list row moves through mixing → transcribing → summarizing and lands on a green check.
- [ ] The row title is a real title from the model, not a date.
- [ ] The detail view shows a summary and a timestamped transcript.
- [ ] Quit and relaunch — the meeting is still listed (index rebuilt from disk).

Then verify the failure path:

- [ ] Open Settings, clear the API key, Save. Record a short meeting.
- [ ] The row shows a warning; the detail view says the API key is missing and shows "Your audio is safe."
- [ ] Restore the key, press **Retry**, and confirm the summary generates without re-transcribing.

- [ ] **Step 4: Run the package tests once more**

Run: `cd MeetingCore && swift test`
Expected: PASS, 35 tests.

- [ ] **Step 5: Commit**

```bash
git add MeetingRecorder/Views/MeetingDetailView.swift \
        MeetingRecorder/Views/SettingsView.swift
git commit -m "feat: add meeting detail view, settings, and retry"
```

---

## Verification checklist

Run before calling the feature done:

- [ ] `cd MeetingCore && swift test` — 35 tests pass
- [ ] `MeetingRecorder/docs/manual-smoke-test.md` — every box ticked
- [ ] Task 13 Step 3 end-to-end check — every box ticked
- [ ] `git log --oneline` shows one commit per task
- [ ] `grep -ri "sk-ant" --include="*.swift" --include="*.json" --include="*.md" .` returns nothing
