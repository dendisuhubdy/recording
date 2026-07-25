import Foundation

/// Which audio file the player should open for a meeting.
public enum PlaybackTrack: Equatable, Sendable {
    /// The normal case: both sides of the conversation.
    case mixed(URL)
    /// Mixing never produced a file, so only the local microphone is available.
    /// Playback works, but the listener hears one half of the meeting.
    case micOnly(URL)

    public var url: URL {
        switch self {
        case .mixed(let url), .micOnly(let url): return url
        }
    }
}

extension MeetingStore {
    /// The best available audio for a meeting, or `nil` when there is nothing to
    /// play.
    ///
    /// A zero-byte file counts as missing. A pipeline stage killed mid-write
    /// leaves one behind, and it would otherwise fail at `AVAudioPlayer` init —
    /// after the UI had already committed to showing a player.
    public func playbackTrack(for id: UUID) -> PlaybackTrack? {
        if hasAudio(at: mixedURL(for: id)) { return .mixed(mixedURL(for: id)) }
        if hasAudio(at: micURL(for: id)) { return .micOnly(micURL(for: id)) }
        return nil
    }

    private func hasAudio(at url: URL) -> Bool {
        guard
            let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int
        else { return false }
        return size > 0
    }
}
