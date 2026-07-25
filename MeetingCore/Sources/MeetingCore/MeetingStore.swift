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
    public func transcriptURL(for id: UUID) -> URL {
        folder(for: id).appending(path: "transcript.json")
    }
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
        // Date encoding is deliberately left at the default (.deferredToDate),
        // which writes `timeIntervalSinceReferenceDate` — Date's own internal
        // representation — so a write/read round-trip is bit-exact.
        //
        // Every "nicer" option loses precision and makes stored dates mutate on
        // round-trip: .iso8601 truncates sub-second entirely, an ISO string with
        // fractional seconds gets only milliseconds, and .secondsSince1970 shifts
        // the epoch by 978307200.0 in both directions, losing low-order bits.
        // meta.json is primarily a machine-recovery record; an exact number beats
        // a lossy timestamp.
        try FileManager.default.createDirectory(
            at: folder(for: metadata.id), withIntermediateDirectories: true)
        try encoder.encode(metadata).write(to: metadataURL(for: metadata.id), options: .atomic)
    }

    public func read(id: UUID) throws -> MeetingMetadata {
        let decoder = JSONDecoder()
        return try decoder.decode(
            MeetingMetadata.self, from: Data(contentsOf: metadataURL(for: id)))
    }

    /// Newest first. Folders whose metadata cannot be read are skipped rather
    /// than throwing — one corrupt meeting must not hide all the others.
    public func allMeetings() throws -> [MeetingMetadata] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        return
            folders
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? read(id: $0) }
            .sorted { $0.date > $1.date }
    }

    public func delete(id: UUID) throws {
        try FileManager.default.removeItem(at: folder(for: id))
    }
}
