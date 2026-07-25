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
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(count)
                )
            else { throw AudioMixerError.cannotAllocateBuffer }
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
