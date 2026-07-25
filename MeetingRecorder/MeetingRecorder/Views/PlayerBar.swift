import MeetingCore
import SwiftUI

struct PlayerBar: View {
    let track: PlaybackTrack
    let player: AudioPlayerController

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let errorMessage = player.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    controls
                    if case .micOnly = track {
                        Text("Mixing failed — playing your microphone track only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                // A zero-length upper bound makes Slider misbehave, and duration
                // is zero until a file is open.
                in: 0...max(player.duration, 0.01)
            )
            .accessibilityLabel("Playback position")

            Text("\(RecordButton.format(player.currentTime)) / \(RecordButton.format(player.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func toggle() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }
}
