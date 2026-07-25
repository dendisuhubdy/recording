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
///
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
            NSLog(
                "RecordingEngine: failed to write %@: %@",
                url.lastPathComponent, error.localizedDescription)
        }
    }

    func close() { file = nil }
}
