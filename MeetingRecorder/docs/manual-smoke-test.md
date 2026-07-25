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

## Handy commands

```bash
# Newest meeting folder, with file sizes
ls -lh "$HOME/Library/Application Support/MeetingRecorder/Meetings/"$(
  ls -t "$HOME/Library/Application Support/MeetingRecorder/Meetings/" | head -1)

# Confirm the two raw captures actually contain audio
afinfo "$HOME/Library/Application Support/MeetingRecorder/Meetings/"*/mic.caf | head
```
