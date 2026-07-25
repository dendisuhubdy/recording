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
    let player = AudioPlayerController()

    @ObservationIgnored private let engine: RecordingEngine
    @ObservationIgnored private var currentMeetingID: UUID?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(store: MeetingStore? = nil, modelContext: ModelContext) {
        // Resolved inside the initializer rather than as a default argument:
        // default arguments evaluate in a nonisolated context, and creating the
        // storage directory is MainActor work.
        let store = store ?? MeetingStore(root: .defaultRootCreatingIfNeeded())
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
            errorMessage =
                (error as? LocalizedError)?.errorDescription
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
        // Before the permission checks, not after: a denied permission would
        // otherwise leave a meeting playing underneath the permission sheet.
        // Capturing system audio while replaying one would also fold the old
        // meeting into the new recording.
        player.stop()

        if PermissionChecker.microphoneStatus() != .granted,
            await PermissionChecker.requestMicrophone() == false
        {
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
            errorMessage =
                (error as? LocalizedError)?.errorDescription
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
            var metadata =
                (try? store.read(id: id))
                ?? MeetingMetadata(id: id, title: "", date: .now)
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
