# Meeting Recorder

A macOS app with one red button. It records your meeting — your microphone and
the other participants' audio — transcribes it on your Mac, and summarizes it
with Claude.

## What leaves your computer

Be clear on this before you record anyone.

| Data | Where it goes |
|---|---|
| **Meeting audio** | Never leaves your Mac. Transcription runs entirely on-device. |
| **Transcript text** | **Sent to the Anthropic API** to generate the summary, using your own API key. A transcript contains everything everyone said in the meeting. |
| **Your API key** | Stored in your macOS Keychain. Nowhere else. |

There is no backend, no account, no telemetry, and no analytics. This app talks
to exactly one server — Anthropic's — and only to summarize a transcript.

If you do not want transcripts sent anywhere, leave the API key blank. Recording
and transcription work without it; you just will not get summaries.

**Recording other people:** in many jurisdictions it is illegal to record a
conversation without the consent of the people in it. This app does not check,
warn, or enforce. That is your responsibility.

## Requirements

- macOS 26 or later
- An [Anthropic API key](https://console.anthropic.com/) for summaries (optional)

## Install

Download the latest `.dmg` from [summly.xyz](https://summly.xyz), open it, and
drag Meeting Recorder to Applications.

The app is signed and notarized by Apple, so it opens normally — no
right-click-Open workaround needed.

## Setup

1. Launch the app and press **⌘,** to open Settings.
2. Paste your Anthropic API key and press **Save**. It goes to your Keychain.
3. Press the red button. macOS will ask for **Microphone** and **Screen
   Recording** permission the first time.

Screen Recording permission is what lets the app capture the other
participants' audio. It records audio only — no video is ever written to disk.

## Build from source

```bash
git clone https://github.com/dendisuhubdy/recording.git
cd recording
swift test --package-path MeetingCore   # run the test suite
open MeetingRecorder/MeetingRecorder.xcodeproj
```

Building for yourself needs no signing setup. Xcode's automatic signing is
enough to run it locally.

## How it works

Recording writes microphone and system audio to two separate files and does no
mixing while capture is running — the real-time path stays as simple as
possible, because that is the one place a bug costs you the meeting. Everything
after that (mixing, transcription, summarization) happens once you press stop,
and each stage can be retried on its own without redoing the others.

Your audio is never deleted automatically. A meeting whose summary failed is
still a meeting with a full transcript.

## License

GPL-3.0. See [LICENSE](LICENSE).
