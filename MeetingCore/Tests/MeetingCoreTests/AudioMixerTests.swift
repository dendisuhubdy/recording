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
    return Array(
        UnsafeBufferPointer(
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
