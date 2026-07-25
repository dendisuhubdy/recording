import AVFoundation
import CoreMedia

extension CMSampleBuffer {
    /// Wraps this buffer's audio as an `AVAudioPCMBuffer` without copying samples.
    /// Returns nil for non-audio buffers (the discarded screen frames).
    ///
    /// Explicitly `nonisolated`: this target defaults to MainActor isolation, but
    /// this is called from ScreenCaptureKit's audio delivery queue. Leaving it
    /// implicitly MainActor is a warning today and an error under Swift 6 mode,
    /// and misdescribes where the code actually runs.
    nonisolated func asPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
            var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription)?.pointee,
            let format = AVAudioFormat(streamDescription: &asbd)
        else { return nil }

        return try? withAudioBufferList { audioBufferList, _ in
            AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
}
