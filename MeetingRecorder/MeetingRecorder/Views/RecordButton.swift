import SwiftUI

struct RecordButton: View {
    let isRecording: Bool
    let elapsed: TimeInterval
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 120, height: 120)
                        .shadow(radius: isRecording ? 12 : 4)
                    if isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white)
                            .frame(width: 40, height: 40)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")

            Text(isRecording ? Self.format(elapsed) : "Ready")
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(isRecording ? .primary : .secondary)
                .contentTransition(.numericText())
        }
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
