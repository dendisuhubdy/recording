# Meeting Playback — Design

**Date:** 2026-07-25
**Status:** Approved, ready for implementation planning

## Summary

Play a recorded meeting's audio back through the system output, from the meeting
detail view. Play/pause, a scrubber, and elapsed/total time. Nothing else.

This closes the gap where the app records audio, transcribes it, and summarizes
it, but gives no way to hear what was captured — the one check that tells you
whether a recording actually worked.

## Environment

Unchanged from the main design: macOS 26, SwiftUI, `MeetingCore` for logic that
can be tested without hardware, app target for anything touching audio devices.

## Decisions

| Decision | Chosen | Rejected |
|---|---|---|
| Scope | Plain player: play/pause, scrub, elapsed/total | Transcript-synced playback — click a line to seek, highlight the spoken line. Deferred, not discarded; the segment start times already exist to support it |
| Track | `mixed.m4a`, falling back to `mic.caf` | Mixed only (a meeting that failed at mixing becomes un-listenable in-app despite the raw audio being on disk); a Mixed/Mic/System picker (a debugging control in everyday UI, and triples the states to test) |
| Record clash | Pressing record silently stops playback | Confirmation sheet (puts a modal in front of the one action that must never be slow); leaving them independent (silently contaminates the new recording with the replayed one) |
| Engine | `AVAudioPlayer` in an `@Observable` controller | `AVPlayer` + `AVPlayerView` (a video control in an audio app); `@State` local to the detail view (cannot satisfy the record clash without plumbing back to `AppModel` anyway) |
| Player ownership | `AppModel` | The detail view — but `startRecording()` must be able to stop playback |

Deliberately excluded: volume control (the system volume already exists) and
playback speed.

## Architecture

### `MeetingCore` — track resolution

Pure logic, no audio hardware, therefore unit tested:

```swift
public enum PlaybackTrack: Equatable {
    case mixed(URL)     // normal — both sides of the conversation
    case micOnly(URL)   // mixing failed — your side only, degraded
}

extension MeetingStore {
    public func playbackTrack(for id: UUID) -> PlaybackTrack?
}
```

Resolution order: `mixed.m4a` if it exists and is non-empty; else `mic.caf` if it
exists and is non-empty; else `nil`.

The non-empty check is load-bearing. A pipeline stage killed mid-write leaves a
zero-byte file, and a zero-byte file fails at `AVAudioPlayer` init — after the UI
has already committed to showing a player. Screening it here turns a confusing
error into the correct "nothing to play" state.

### App target — `AudioPlayerController`

`@MainActor @Observable`, wrapping `AVAudioPlayer`.

- State: `isPlaying`, `currentTime`, `duration`, `loadedMeetingID`, `errorMessage`
- Behaviour: `load(meetingID:track:)`, `play()`, `pause()`, `seek(to:)`, `stop()`

No unit tests, for the reason `RecordingEngine` has none: it needs a real output
device, and the failure modes that matter cannot be reproduced by a mock. It is
covered by the manual smoke test instead.

`currentTime` advances from a ~10 Hz `Task` tick while playing, mirroring
`AppModel.startTicking()` rather than introducing a second timing pattern.

### App target — `PlayerBar`

A SwiftUI view in `Views/`: play/pause button, a `Slider` bound to `currentTime`,
and `elapsed / total` rendered with the existing `RecordButton.format`. In the
`.micOnly` case it also shows a caption explaining that mixing failed and only
the microphone track is playing.

Placed directly under the header in `MeetingDetailView`, above the failure
banner: title, then listen, then what went wrong, then read.

### Wiring

`AppModel` gains `let player = AudioPlayerController()`.

`startRecording()` calls `player.stop()` as its **first** statement — before the
permission checks, so playback stops even when the recording then fails to start.
Otherwise a denied permission would leave audio playing under a permission sheet.

## Data flow

1. `MeetingDetailView.task(id:)` fires on meeting switch. It calls `player.stop()`,
   then resolves the track via `store.playbackTrack(for:)`.
2. `nil` → no player is rendered.
3. Non-`nil` → `load(meetingID:track:)` runs immediately and `PlayerBar` renders.

   Loading eagerly rather than on first press is deliberate. `PlayerBar` shows
   `elapsed / total`, and `total` is only known once the file is open — deferring
   the load would mean rendering a player with no duration until the user presses
   play. Opening an `AVAudioPlayer` reads the file header and starts no audio, so
   the cost is negligible, and it surfaces a corrupt file when the meeting is
   selected instead of on first press.

   `total` comes from `AVAudioPlayer.duration`, not `MeetingRecord.duration`. The
   metadata figure is what the recorder believed it captured; the file duration is
   what is actually there, and a divergence between them is precisely the kind of
   bad recording this feature exists to expose.
4. Play → the tick task starts, updating `currentTime`.
5. Scrub → `seek(to:)`, which is safe whether or not playback is running.
6. End of file → reset to 0 and show the play icon. No auto-advance to the next
   meeting.

## Error handling

| Case | Behaviour |
|---|---|
| No audio files, or all zero-byte | No player rendered. The failure banner already explains why |
| `AVAudioPlayer` init throws (corrupt file) | Inline message replaces the controls. No crash |
| Meeting deleted while playing | `stop()` |
| Meeting switched while playing | `stop()`, then resolve the new track |
| Record pressed while playing | `stop()`, then proceed with recording |

Nothing here deletes or rewrites audio. Playback is strictly read-only against
the meeting folder.

## Testing

**Unit — `MeetingCoreTests`, track resolution:**

- `mixed.m4a` present and non-empty → `.mixed`
- `mixed.m4a` missing, `mic.caf` present → `.micOnly`
- `mixed.m4a` zero-byte, `mic.caf` present → `.micOnly`
- both missing → `nil`
- both zero-byte → `nil`

**Manual — added to `MeetingRecorder/docs/manual-smoke-test.md`:**

- Audio is audible through the current output device
- The scrubber tracks playback, and dragging it seeks
- Elapsed/total match the recording's real duration
- Pressing record mid-playback stops playback, and the resulting recording does
  not contain the replayed meeting
- A meeting whose mixing failed plays the microphone track with the caption shown

## Out of scope

Transcript-synced playback, waveform display, volume, speed control, keyboard
shortcuts, and playback from the menu bar. Each is additive and none is blocked
by this design.
