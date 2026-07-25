import MeetingCore
import SwiftUI

struct MeetingListView: View {
    let meetings: [MeetingRecord]
    @Binding var selection: UUID?
    let onDelete: (UUID) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(meetings) { meeting in
                MeetingRow(meeting: meeting)
                    .tag(meeting.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { onDelete(meeting.id) }
                    }
            }
        }
        .overlay {
            if meetings.isEmpty {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "waveform",
                    description: Text("Press the red button to record your first meeting.")
                )
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: MeetingRecord

    var body: some View {
        HStack(spacing: 10) {
            StageIndicator(stage: meeting.stage)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).lineLimit(1)
                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if meeting.duration > 0 {
                Text(RecordButton.format(meeting.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct StageIndicator: View {
    let stage: MeetingStage

    var body: some View {
        switch stage {
        case .complete:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .recording:
            Image(systemName: "record.circle").foregroundStyle(.red)
        default:
            ProgressView().controlSize(.small)
        }
    }
}
