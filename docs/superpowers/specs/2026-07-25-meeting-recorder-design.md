# Meeting Recorder — Design

**Date:** 2026-07-25
**Status:** Approved, ready for implementation planning

## Summary

A macOS app with a single red button that records a meeting — your microphone and
the other participants' audio together — then transcribes it on-device and
summarizes it with the Claude API. Past meetings live in an in-app library with
their transcript and summary.

Personal tool, run from Xcode. Not sandboxed, not notarized, not shipped.

## Environment

- macOS 26.5, Xcode 26.6
- SwiftUI, SwiftData
- ScreenCaptureKit (audio capture), Speech (on-device transcription),
  AVFoundation (offline mixing)
- Claude API over raw `URLSession` — there is no official Anthropic SDK for Swift

## Decisions

These were settled during design. Each records the alternative rejected, so a
future reader knows the choice was made rather than defaulted into.

| Decision | Chosen | Rejected |
|---|---|---|
| Audio sources | Mic + system audio, mixed to one track | Mic only (misses remote participants); separate labelled tracks (deferred) |
| Capture API | ScreenCaptureKit `SCStream` | CoreAudio process tap (more code, more failure modes); BlackHole (requires user-installed driver) |
| Transcription | On-device `SpeechAnalyzer` | Cloud Whisper-class (audio leaves the machine, costs per meeting) |
| Summarization | Claude API (`claude-opus-5`) | Apple Foundation Models (weaker summaries, small context) |
| Transcription timing | After stop, from the saved file | Live streaming (couples recording to the speech engine) |
| Speaker labels | None — one flat transcript | Channel-based "me vs them" (deferred); full diarization (out of scope) |
| App surface | Menu bar + main window | Window-only; menu-bar-only |
| Distribution | Run from Xcode, personal use | Signed `.app`; App Store |

### Why mixing happens offline

`RecordingEngine` writes microphone and system audio to two separate files and
performs no mixing during the recording. ScreenCaptureKit delivers `.audio` and
`.microphone` as independent sample-buffer streams on separate queues; mixing
them live means sample-rate conversion and drift correction on the real-time
audio thread — the one place where a bug costs the user the actual meeting.

Two passthrough writes are nearly impossible to get wrong. The timing-sensitive
work moves to a stage that runs after the audio is already safe on disk and can
be retried. The user still gets one mixed track, as specified; the two raw files
are a cheap byproduct and the escape hatch if channel-based speaker labelling is
added later.

## Architecture

Six units. Each has one responsibility, a defined interface, and can be
understood without reading the others.

| Unit | Responsibility | Depends on |
|---|---|---|
| `RecordingEngine` | Own the `SCStream`; write raw audio to disk | ScreenCaptureKit |
| `AudioMixer` | Combine two raw files into one mixed `.m4a`, offline | AVFoundation |
| `Transcriber` (protocol) | Audio file → timestamped text segments | Speech |
| `Summarizer` (protocol) | Transcript → structured summary | URLSession |
| `MeetingStore` | Disk layout + SwiftData index | SwiftData |
| `PipelineCoordinator` | Stage state machine; owns retry | all of the above |

`Transcriber` and `Summarizer` are protocols so the pipeline can be tested
without a speech model or a network, and so a different backend can be
substituted later without touching the recording layer.

### Data flow

```
[Red button] → RecordingEngine ──┬─→ mic.caf
                                 └─→ system.caf
   [Stop]  → AudioMixer          ──→ mixed.m4a
          → Transcriber          ──→ transcript.json   (on-device)
          → Summarizer           ──→ summary.md        (network)
          → MeetingStore         ──→ row in library
```

### Storage layout

One directory per meeting, so a failed run is inspectable and deletable by hand.

```
~/Library/Application Support/MeetingRecorder/
  Meetings/<uuid>/
    mic.caf          raw microphone capture
    system.caf       raw system audio capture
    mixed.m4a        offline mix, input to transcription
    transcript.json  [{start, end, text}]
    summary.md       rendered summary
    meta.json        id, title, date, duration, stage, error
```

SwiftData stores only the index — id, title, date, duration, stage, folder path.
Audio and text stay as plain files on disk, greppable and not trapped in a
database.

**Source of truth:** the SwiftData index is authoritative for the library view.
`meta.json` duplicates the same fields as a self-describing sidecar so a meeting
folder remains meaningful on its own — it is what a rebuild reads from if the
index is lost or a folder is copied elsewhere. Writes go to both; on
disagreement, `meta.json` wins, because the folder is the durable artifact.

## Component detail

### RecordingEngine

An `SCStream` configured with `capturesAudio = true` and
`captureMicrophone = true`. ScreenCaptureKit is video-shaped, so the stream also
captures a minimal 2×2 pixel display region whose frames are discarded; this is
the standard way to obtain an audio-only `SCStream`.

Two `SCStreamOutput` handlers on separate queues write straight through:

- `SCStreamOutputType.audio` → `system.caf`
- `SCStreamOutputType.microphone` → `mic.caf`

No mixing, no conversion, no allocation beyond the file write. Stop tears the
stream down and closes both files.

### AudioMixer

Reads `mic.caf` and `system.caf`, resamples to a common format if they differ,
sums them, and writes `mixed.m4a` (AAC). Runs off the main thread after
recording has stopped. Guards against clipping when both sources are loud.

Files of differing length are handled by padding the shorter with silence —
the microphone stream can start a moment after the system stream.

### Transcriber

`SpeechAnalyzer` with a `SpeechTranscriber` module for the user's locale.

On first launch the app checks `AssetInventory` and downloads the locale model
if absent. This is a one-time download of a few hundred megabytes and gets its
own visible progress state, so it is not mistaken for a hung first recording.

`mixed.m4a` is fed through as `AVAudioPCMBuffer`s; results are collected with
their `audioTimeRange` and written as:

```json
[ {"start": 12.4, "end": 18.9, "text": "…"} ]
```

Timestamps cost nothing to retain and make the transcript view scrubbable.

### Summarizer

Direct `URLSession` request to `POST https://api.anthropic.com/v1/messages`.

- Headers: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`
- Model: `claude-opus-5`
- `stream: true` (SSE)
- `output_config.format` with a JSON schema

**No chunking.** Opus 5 has a 1M-token context window. A three-hour meeting
transcript is roughly 45k tokens and fits in a single call with room to spare;
map-reduce summarization would add complexity for no benefit.

**Streaming is required, not optional.** Thinking is on by default on Opus 5 and
`max_tokens` bounds thinking plus response text together, so `max_tokens` is set
generously and the response is streamed to stay clear of HTTP timeouts.

Response schema:

```
{
  title:          string,
  summary:        string,
  decisions:      string[],
  action_items:   [{ owner: string, task: string }],
  open_questions: string[]
}
```

`title` is what the library row displays — "Q3 roadmap — cut scope on billing"
rather than "Meeting 2026-07-25 14:03".

The API key is stored in the **Keychain**, entered once in Settings. It is never
written to `meta.json`, to `summary.md`, or to any log.

### PipelineCoordinator

State machine over one meeting:

```
idle → recording → mixing → transcribing → summarizing → complete
                      ↓          ↓              ↓
                   failed(stage, error)  ← retryable
```

Each post-recording stage is independently retryable from the failed state
without redoing the stages before it.

### UI

**Menu bar** (`MenuBarExtra`): icon turns red and displays elapsed time while
recording. Click to start/stop, open the main window, or jump to a recent
meeting.

**Main window:** the large red record button at the top, list of past meetings
below. Selecting one opens a detail view with the summary rendered and the
transcript underneath.

**Settings:** Claude API key, microphone device selection.

## Error handling

The governing rule is that **audio is sacred**. Nothing is ever auto-deleted, and
every stage after recording is independently retryable.

| Failure | Behavior |
|---|---|
| Screen Recording or Microphone permission not granted | Explanatory sheet with a deep link to System Settings, shown *before* recording starts |
| Disk full or stream drops mid-meeting | Stop cleanly, retain every byte already written, mark the meeting partial |
| Mixing fails | `mic.caf` and `system.caf` retained; retry available |
| Speech model missing or transcription fails | Audio untouched; retry available |
| No API key, offline, or network error | Transcript saved and readable; summary retryable |
| HTTP 429 | Honor `retry-after` before retrying |
| `stop_reason: "refusal"` | Surface plainly; do not retry the identical request |

A meeting whose summary never generated is still a meeting with a full
transcript, not a failure.

## Testing

Protocol boundaries exist so the pipeline is testable without hardware or
network.

| Unit | Approach |
|---|---|
| `AudioMixer` | Synthetic sine buffers with known values; assert summed output, duration, no clipping, silence-padding of the shorter file |
| `Summarizer` | Fake `URLProtocol`; assert request shape (model id, headers, schema) and SSE parsing; cover 401, 429, refusal, malformed-JSON paths |
| `MeetingStore` | Temp directories; create, list, delete, orphaned-folder handling |
| `PipelineCoordinator` | Fake `Transcriber` and `Summarizer`; assert stage transitions and per-stage retry |
| Transcript model | JSON round-trip |
| `RecordingEngine` | **Not unit tested.** Requires real TCC permission and real system audio; covered by a written manual smoke-test checklist instead |

`RecordingEngine` is excluded deliberately. A unit test that mocks
`SCStream` would assert only that the mock was called, which is theater — the
failure modes that matter (permissions, device changes, drift, silent empty
files) are exactly the ones a mock cannot reproduce.

## Non-goals for v1

Stated explicitly so the implementation plan does not quietly absorb them:

- Speaker diarization or per-speaker labelling
- Live transcript display during recording
- Transcript editing
- Calendar integration or automatic meeting detection
- Cloud sync or multi-device support
- Code signing, notarization, or distribution
- Sandboxing
