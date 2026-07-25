import AppKit
import MeetingCore
import SwiftData
import SwiftUI

@main
struct MeetingRecorderApp: App {
    private let container: ModelContainer
    @State private var model: AppModel

    init() {
        let container = try! ModelContainer(for: MeetingRecord.self)
        self.container = container
        _model = State(initialValue: AppModel(modelContext: container.mainContext))
    }

    var body: some Scene {
        Window("Meeting Recorder", id: "main") {
            MainView(model: model)
                .task { await model.onLaunch() }
        }
        .modelContainer(container)
        .defaultSize(width: 820, height: 560)

        MenuBarExtra {
            Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                Task { await model.toggleRecording() }
            }
            Divider()
            Button("Open Meeting Recorder") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "record.circle")
                .foregroundStyle(model.isRecording ? .red : .primary)
        }

        Settings {
            SettingsView()
        }
    }
}

struct MainView: View {
    @Bindable var model: AppModel
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                RecordButton(
                    isRecording: model.isRecording,
                    elapsed: model.elapsed,
                    action: { Task { await model.toggleRecording() } }
                )
                .padding(.vertical, 24)
                Divider()
                MeetingListView(
                    meetings: model.library.meetings,
                    selection: $selection,
                    onDelete: { model.deleteMeeting(id: $0) }
                )
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 300)
        } detail: {
            if let selection,
                let meeting = model.library.meetings.first(where: { $0.id == selection })
            {
                MeetingDetailView(meeting: meeting, model: model)
            } else {
                ContentUnavailableView("No meeting selected", systemImage: "doc.text")
            }
        }
        .alert(
            "Permission needed",
            isPresented: Binding(
                get: { model.permissionPrompt != nil },
                set: { if !$0 { model.permissionPrompt = nil } }
            ),
            presenting: model.permissionPrompt
        ) { kind in
            Button("Open System Settings") { PermissionChecker.openSettings(for: kind) }
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            Text(kind.explanation)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
