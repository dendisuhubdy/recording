import Foundation
import MeetingCore
import SwiftUI

struct MeetingDetailView: View {
    let meeting: MeetingRecord
    @Bindable var model: AppModel

    @State private var summaryMarkdown: String = ""
    @State private var transcript: Transcript?
    @State private var isRetrying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if meeting.stage == .failed {
                    failureBanner
                }

                if !summaryMarkdown.isEmpty {
                    section("Summary") {
                        Text(LocalizedStringKey(summaryMarkdown))
                            .textSelection(.enabled)
                    }
                }

                if let transcript, !transcript.segments.isEmpty {
                    section("Transcript") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(transcript.segments.enumerated()), id: \.offset) {
                                _, segment in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(RecordButton.format(segment.start))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 68, alignment: .leading)
                                    Text(segment.text).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: meeting.id) { load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title).font(.largeTitle.bold()).textSelection(.enabled)
            HStack(spacing: 8) {
                Text(meeting.date.formatted(date: .complete, time: .shortened))
                if meeting.duration > 0 {
                    Text("·")
                    Text(RecordButton.format(meeting.duration))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var failureBanner: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.failureReason ?? "This meeting did not finish processing.")
                    Text("Your audio is safe. Nothing has been deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isRetrying ? "Retrying…" : "Retry") {
                    isRetrying = true
                    Task {
                        await model.retry(meetingID: meeting.id)
                        isRetrying = false
                        load()
                    }
                }
                .disabled(isRetrying)
            }
            .padding(6)
        }
    }

    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func load() {
        let store = model.store
        summaryMarkdown =
            (try? String(
                contentsOf: store.summaryURL(for: meeting.id),
                encoding: .utf8)) ?? ""
        transcript = (try? Data(contentsOf: store.transcriptURL(for: meeting.id)))
            .flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
    }
}
