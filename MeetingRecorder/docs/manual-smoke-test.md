# RecordingEngine manual smoke test

`RecordingEngine` is not unit tested — it needs real TCC permission and real
system audio, and the failure modes that matter (permission denial, device
changes, silent empty files) are exactly the ones a mock cannot reproduce.
Run this checklist after changing it.

## Setup
Play audio from another app (a YouTube video works) and be ready to speak.

## Steps
1. Launch the app. Start a recording.
   - [ ] macOS prompts for Microphone access on first run.
   - [ ] macOS prompts for Screen Recording access on first run.
   - [ ] The menu bar icon turns red and the elapsed timer counts up.
2. Speak for ~5 seconds while the other app plays audio.
3. Stop the recording.
4. Open `~/Library/Application Support/MeetingRecorder/Meetings/<newest>/`.
   - [ ] `mic.caf` exists and is larger than 10 KB.
   - [ ] `system.caf` exists and is larger than 10 KB.
   - [ ] Playing `mic.caf` in QuickTime plays back your voice.
   - [ ] Playing `system.caf` plays back the other app's audio, not your voice.
   - [ ] `mixed.m4a` contains both.

## Failure cases
5. Deny Screen Recording in System Settings, relaunch, try to record.
   - [ ] An explanatory sheet appears with a working button to System Settings.
   - [ ] The app does not crash and no empty meeting folder is left behind.
6. Start a recording, then stop it after ~1 second.
   - [ ] Both files still exist and are non-empty.

## Playback

`AudioPlayerController` is not unit tested either — it needs a real output
device, and silence, an unopenable file, or a device vanishing mid-playback are
not reproducible with a mock. Run this after changing it.

7. Select the meeting recorded above.
   - [ ] A player bar appears under the title, showing `00:00:00 / <duration>`.
   - [ ] The total matches the recording's real length, not zero.
8. Press play.
   - [ ] Audio comes out of the current output device.
   - [ ] The elapsed time and the slider advance together.
9. Drag the slider to the middle.
   - [ ] Playback jumps to that point, both while playing and while paused.
10. Let it play to the end.
   - [ ] The bar resets to `00:00:00` and shows the play icon again.
   - [ ] It does not roll on into another meeting.
11. Press play, then press the red record button while audio is still playing.
   - [ ] Playback stops immediately, with no confirmation dialog.
   - [ ] Stop the new recording and play it back: it must **not** contain the
         meeting that was playing when you pressed record. This is the whole
         reason playback stops — the system-audio capture would otherwise
         record the replay.
12. Select a different meeting while one is playing.
   - [ ] Playback stops, and the bar shows the new meeting's duration from
         `00:00:00` — never the previous meeting's position.

### Degraded cases
13. Delete `mixed.m4a` from a meeting folder, then reopen that meeting.
   - [ ] The player still appears and plays `mic.caf`.
   - [ ] The caption reads "Mixing failed — playing your microphone track only."
14. Truncate a meeting's audio to zero bytes
    (`: > mixed.m4a; : > mic.caf`), then reopen it.
   - [ ] No player bar appears at all, and the app does not crash.

## Handy commands

```bash
# Newest meeting folder, with file sizes
ls -lh "$HOME/Library/Application Support/MeetingRecorder/Meetings/"$(
  ls -t "$HOME/Library/Application Support/MeetingRecorder/Meetings/" | head -1)

# Confirm the two raw captures actually contain audio
afinfo "$HOME/Library/Application Support/MeetingRecorder/Meetings/"*/mic.caf | head
```
