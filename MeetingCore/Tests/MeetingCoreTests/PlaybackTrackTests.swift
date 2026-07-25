import Foundation
import Testing

@testable import MeetingCore

/// Writes `byteCount` bytes to `url`, creating the parent folder. A zero count
/// produces the empty file a stage killed mid-write leaves behind.
private func writeFile(_ url: URL, bytes byteCount: Int) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: byteCount).write(to: url)
}

@Test func playbackPrefersTheMixedTrack() throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)
    let id = UUID()
    try writeFile(store.mixedURL(for: id), bytes: 1024)
    try writeFile(store.micURL(for: id), bytes: 1024)

    #expect(store.playbackTrack(for: id) == .mixed(store.mixedURL(for: id)))
}

@Test func playbackFallsBackToTheMicWhenMixingNeverRan() throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)
    let id = UUID()
    try writeFile(store.micURL(for: id), bytes: 1024)

    #expect(store.playbackTrack(for: id) == .micOnly(store.micURL(for: id)))
}

@Test func playbackTreatsAnEmptyMixedFileAsMissing() throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)
    let id = UUID()
    // A stage killed mid-write leaves a zero-byte file. Playing it would fail
    // at AVAudioPlayer init, after the UI has committed to showing a player.
    try writeFile(store.mixedURL(for: id), bytes: 0)
    try writeFile(store.micURL(for: id), bytes: 1024)

    #expect(store.playbackTrack(for: id) == .micOnly(store.micURL(for: id)))
}

@Test func playbackHasNothingToPlayWhenBothFilesAreMissing() throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)

    #expect(store.playbackTrack(for: UUID()) == nil)
}

@Test func playbackHasNothingToPlayWhenBothFilesAreEmpty() throws {
    let temp = try TempDirectory()
    let store = MeetingStore(root: temp.url)
    let id = UUID()
    try writeFile(store.mixedURL(for: id), bytes: 0)
    try writeFile(store.micURL(for: id), bytes: 0)

    #expect(store.playbackTrack(for: id) == nil)
}
