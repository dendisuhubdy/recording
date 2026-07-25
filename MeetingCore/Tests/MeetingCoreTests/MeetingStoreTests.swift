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
