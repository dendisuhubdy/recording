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
    case cannotConvert
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
        let trackA = try readConverted(try AVAudioFile(forReading: a))
        let trackB = try readConverted(try AVAudioFile(forReading: b))
        let frames = AVAudioFramePosition(max(trackA.count, trackB.count))
        guard frames > 0 else { throw AudioMixerError.noAudio }

        var summed = [Float](repeating: 0, count: Int(frames))
        for track in [trackA, trackB] {
            for i in track.indices { summed[i] += track[i] }
        }

        let peak = summed.reduce(Float(0)) { max($0, abs($1)) }
        let gain: Float = peak > 1.0 ? 1.0 / peak : 1.0
        if gain != 1.0 {
            for i in summed.indices { summed[i] *= gain }
        }

        let output = try AVAudioFile(
            forWriting: outputURL, settings: processingFormat.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(frames)
            )
        else { throw AudioMixerError.cannotAllocateBuffer }
        outputBuffer.frameLength = AVAudioFrameCount(frames)
        summed.withUnsafeBufferPointer { source in
            outputBuffer.floatChannelData![0].update(
                from: source.baseAddress!, count: Int(frames))
        }
        try output.write(from: outputBuffer)

        return MixReport(peak: peak, frameCount: frames, didNormalize: gain != 1.0)
    }

    /// Reads a whole file as mono 48 kHz float, resampling and downmixing as
    /// needed.
    ///
    /// The two capture sources do not agree on format and never did: the system
    /// stream arrives at the configured 48 kHz stereo, while the microphone
    /// arrives at whatever rate the device negotiates — 24 kHz mono on the
    /// machine this was found on. Summing them frame-by-frame made the mic play
    /// back at twice speed and stop halfway through the meeting, and silently
    /// discarded the right channel of the system audio.
    private static func readConverted(_ file: AVAudioFile) throws -> [Float] {
        guard file.length > 0 else { return [] }
        let sourceFormat = file.processingFormat
        let chunk: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunk) else {
            throw AudioMixerError.cannotAllocateBuffer
        }

        // Read in chunks and accumulate. A single `read(into:)` returns fewer
        // frames than the file holds — it was quietly dropping the tail of
        // every recording.
        var mono: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            mono.append(contentsOf: downmixToMono(buffer))
        }

        guard sourceFormat.sampleRate != processingFormat.sampleRate else { return mono }
        return try resample(mono, from: sourceFormat.sampleRate)
    }

    /// Averages every channel into one.
    ///
    /// `AVAudioConverter` will not do this: asked to go from stereo to mono it
    /// selects the first channel and discards the rest, so the right-hand side
    /// of the system audio would vanish.
    private static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
        }
        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            for i in 0..<frameCount { mono[i] += channels[channel][i] }
        }
        let scale = 1 / Float(channelCount)
        for i in mono.indices { mono[i] *= scale }
        return mono
    }

    /// Mono-to-mono sample rate conversion, which is the one thing
    /// `AVAudioConverter` does exactly right.
    private static func resample(_ samples: [Float], from sampleRate: Double) throws -> [Float] {
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: sourceFormat, to: processingFormat),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw AudioMixerError.cannotConvert }
        // The conversion block runs synchronously on this thread, so neither the
        // buffer nor the flag below is ever touched concurrently.
        nonisolated(unsafe) let input = buffer

        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            input.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }

        let ratio = processingFormat.sampleRate / sampleRate
        // Headroom for the resampler's filter delay, which can emit slightly
        // more than the naive ratio predicts.
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 4096
        guard
            let output = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: capacity)
        else { throw AudioMixerError.cannotAllocateBuffer }

        // The block runs synchronously on this thread; the flag is not shared.
        nonisolated(unsafe) var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }

        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
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
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: source.processingFormat, frameCapacity: chunk
            )
        else { throw AudioMixerError.cannotAllocateBuffer }
        while source.framePosition < source.length {
            try source.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            try destination.write(from: buffer)
        }

        return report
    }
}
