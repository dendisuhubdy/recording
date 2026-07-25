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

/// Writes a constant at an arbitrary format. The capture path does not hand us
/// 48 kHz mono on both sources: ScreenCaptureKit delivers system audio at the
/// configured 48 kHz stereo, while the microphone arrives at whatever rate the
/// device negotiates — 24 kHz mono on the machine this was found on.
private func writeConstant(
    _ value: Float, seconds: Double, sampleRate: Double, channels: AVAudioChannelCount,
    to url: URL
) throws {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: channels, interleaved: false)!
    let frames = Int(sampleRate * seconds)
    let file = try AVAudioFile(
        forWriting: url, settings: format.settings,
        commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<Int(channels) {
        for i in 0..<frames { buffer.floatChannelData![channel][i] = value }
    }
    try file.write(from: buffer)
}

private func writeStereo(
    left: Float, right: Float, seconds: Double, sampleRate: Double, to url: URL
) throws {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: 2, interleaved: false)!
    let frames = Int(sampleRate * seconds)
    let file = try AVAudioFile(
        forWriting: url, settings: format.settings,
        commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
        buffer.floatChannelData![0][i] = left
        buffer.floatChannelData![1][i] = right
    }
    try file.write(from: buffer)
}

/// Reads in chunks and accumulates. A single `read(into:)` can return fewer
/// frames than the file holds, which silently truncated the tail.
private func readAll(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let chunk: AVAudioFrameCount = 8192
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
    var samples: [Float] = []
    while file.framePosition < file.length {
        try file.read(into: buffer, frameCount: chunk)
        if buffer.frameLength == 0 { break }
        samples.append(
            contentsOf: UnsafeBufferPointer(
                start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    return samples
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
    #expect(abs(samples[0] - 0.75) < 0.0001)  // both sources overlap here
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

@Test func resamplesASourceRecordedAtALowerRate() throws {
    let temp = try TempDirectory()
    let mic = temp.url.appending(path: "mic.caf")
    let system = temp.url.appending(path: "system.caf")
    let out = temp.url.appending(path: "out.caf")
    // One second each, but at different rates — exactly what the capture path
    // produces. Summed frame-by-frame the mic would occupy only half the
    // output, playing back at 2x and stopping halfway.
    try writeConstant(0.5, seconds: 1.0, sampleRate: 24_000, channels: 1, to: mic)
    try writeConstant(0.25, seconds: 1.0, sampleRate: 48_000, channels: 1, to: system)

    try AudioMixer.mixToFloatFile(a: mic, b: system, outputURL: out)

    let samples = try readAll(out)
    #expect(samples.count == 48_000)
    // Three quarters of the way through, both sources must still be present.
    #expect(abs(samples[36_000] - 0.75) < 0.01)
}

@Test func downmixesAStereoSourceRatherThanTakingTheLeftChannel() throws {
    let temp = try TempDirectory()
    let mic = temp.url.appending(path: "mic.caf")
    let system = temp.url.appending(path: "system.caf")
    let out = temp.url.appending(path: "out.caf")
    try writeConstant(0.0, seconds: 0.1, sampleRate: 48_000, channels: 1, to: mic)
    // Asymmetric on purpose: equal channels cannot tell a downmix apart from
    // reading channel 0 and discarding the right channel.
    try writeStereo(left: 0.6, right: 0.0, seconds: 0.1, sampleRate: 48_000, to: system)

    try AudioMixer.mixToFloatFile(a: mic, b: system, outputURL: out)

    let samples = try readAll(out)
    // Taking channel 0 alone would leave 0.6 here. Any real downmix folds the
    // silent right channel in and lands well below that.
    #expect(samples[2_400] < 0.5)
}

@Test func mixProducesAPlayableM4AOfTheRightDuration() throws {
    let temp = try TempDirectory()
    let mic = temp.url.appending(path: "mic.caf")
    let system = temp.url.appending(path: "system.caf")
    let mixed = temp.url.appending(path: "mixed.m4a")
    try writeConstant(0.2, frames: 48_000, to: mic)  // 1 second at 48kHz
    try writeConstant(0.2, frames: 48_000, to: system)

    let report = try AudioMixer.mix(micURL: mic, systemURL: system, outputURL: mixed)

    #expect(report.frameCount == 48_000)
    #expect(FileManager.default.fileExists(atPath: mixed.path))
    let encoded = try AVAudioFile(forReading: mixed)
    // AAC pads slightly; assert the duration is about right rather than exact.
    let seconds = Double(encoded.length) / encoded.processingFormat.sampleRate
    #expect(abs(seconds - 1.0) < 0.1)
}
