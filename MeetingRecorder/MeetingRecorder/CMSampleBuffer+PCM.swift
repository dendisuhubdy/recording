import AVFoundation
import CoreMedia

extension CMSampleBuffer {
    /// Wraps this buffer's audio as an `AVAudioPCMBuffer` without copying samples.
    /// Returns nil for non-audio buffers (the discarded screen frames).
    func asPCMBuffer() -> AVAudioPCMBuffer? {
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
