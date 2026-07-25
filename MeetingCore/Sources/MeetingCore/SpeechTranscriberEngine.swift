import AVFoundation
import Foundation
import Speech

/// On-device transcription via `SpeechAnalyzer`.
///
/// Not unit tested: it needs an installed speech model and produces
/// nondeterministic output. The `Transcriber` protocol is what the pipeline is
/// tested against; this type is covered by the manual smoke test.
public struct SpeechTranscriberEngine: Transcriber {
    let locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Final results only, with time ranges attached. No volatile/partial results —
    /// this runs over a finished file, so there is nothing to preview.
    private static func makeModule(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    private static func resolveLocale(_ requested: Locale) async throws -> Locale {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        else { throw TranscriberError.localeUnsupported(requested.identifier) }
        return supported
    }

    /// Downloads the speech model if it is not already installed. Call this at
    /// launch so the download is a visible one-time step rather than an
    /// apparently-hung first recording.
    public static func ensureModelInstalled(
        locale requested: Locale = .current,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        let locale = try await resolveLocale(requested)
        let module = makeModule(locale: locale)
        guard await AssetInventory.status(forModules: [module]) != .installed else { return }
        guard
            let request = try await AssetInventory.assetInstallationRequest(
                supporting: [module]
            )
        else { throw TranscriberError.modelUnavailable }
        progress?(request.progress)
        try await request.downloadAndInstall()
    }

    public func transcribe(audioFileAt url: URL) async throws -> Transcript {
        let resolvedLocale = try await Self.resolveLocale(locale)
        let module = Self.makeModule(locale: resolvedLocale)

        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw TranscriberError.modelUnavailable
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriberError.audioUnreadable(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: [module])

        // Collect results concurrently with the analysis — `results` is an async
        // sequence that finishes when the analyzer finalizes.
        let collector = Task { () -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in module.results {
                let text = String(result.text.characters)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                segments.append(
                    TranscriptSegment(
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        text: text
                    ))
            }
            return segments
        }

        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw TranscriberError.analysisFailed(error.localizedDescription)
        }

        do {
            return Transcript(segments: try await collector.value)
        } catch {
            throw TranscriberError.analysisFailed(error.localizedDescription)
        }
    }
}
