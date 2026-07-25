import AVFoundation
import Foundation
import MeetingCore
import Observation

/// Plays a recorded meeting through the current system output.
///
/// Not unit tested, for the same reason `RecordingEngine` is not: it needs a
/// real output device, and the failure modes that matter — silence, a file that
/// will not open, a device disappearing mid-playback — are exactly the ones a
/// mock cannot reproduce. Covered by the manual smoke test instead.
@MainActor
@Observable
final class AudioPlayerController {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var loadedMeetingID: UUID?
    private(set) var errorMessage: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    /// Opens `track` for playback without starting it.
    ///
    /// Loading eagerly rather than on first press is what lets the bar show a
    /// real total duration immediately, and surfaces an unopenable file when the
    /// meeting is selected rather than when the user presses play.
    func load(meetingID: UUID, track: PlaybackTrack) {
        guard loadedMeetingID != meetingID else { return }
        halt()
        loadedMeetingID = meetingID
        do {
            let player = try AVAudioPlayer(contentsOf: track.url)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            errorMessage = nil
        } catch {
            player = nil
            duration = 0
            errorMessage = "This recording could not be opened."
        }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTicking()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
    }

    /// Safe whether or not playback is running.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(time, 0), player.duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Halts playback and rewinds to the start, keeping the file loaded so the
    /// bar stays on screen. Called when a recording starts — replaying a meeting
    /// while capturing system audio would fold the old audio into the new file.
    func stop() {
        halt()
    }

    private func halt() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        stopTicking()
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                // AVAudioPlayer reports isPlaying == false once it reaches the
                // end. Reset rather than auto-advancing to another meeting.
                if !player.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.currentTime = 0
                    player.currentTime = 0
                    self.stopTicking()
                }
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
