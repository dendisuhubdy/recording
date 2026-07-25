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
