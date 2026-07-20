import Foundation
import WhisperKit

// MARK: - Model Size

enum WhisperModelSize: String, CaseIterable {
    case small  = "whisper-small"
    case medium = "whisper-medium"
}

// MARK: - TranscriptionManager

/// Loads a WhisperKit model from the local Models directory and transcribes
/// buffered audio chunks in 5-second windows (80 000 samples @ 16 kHz).
///
/// Not isolated to `@MainActor` — WhisperKit inference is CPU/ANE-bound and
/// can take 1–3 seconds; callers run it off the main actor via `async`.
final class TranscriptionManager: ObservableObject {

    // MARK: - Constants

    /// 5 seconds × 16 000 samples/s
    private static let windowSize: Int = 5 * 16_000

    // MARK: - Private State

    private var whisperKit: WhisperKit?
    private var sampleBuffer: [Float] = []

    // MARK: - Init

    init() {}

    // MARK: - Public API

    /// Loads the WhisperKit model from
    /// `~/Library/Application Support/MeetingMinutes/Models/<size>/`.
    ///
    /// - Parameters:
    ///   - size: Which model variant to load.
    ///   - progress: Called with values in [0, 1] as the model components
    ///     finish loading. WhisperKit does not surface granular progress, so
    ///     we emit 0.0 at start and 1.0 on completion.
    func loadModel(size: WhisperModelSize, progress: @escaping (Double) -> Void) async throws {
        await MainActor.run { progress(0.0) }

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let modelFolder = appSupport
            .appendingPathComponent("MeetingMinutes/Models/\(size.rawValue)")
            .path

        let config = WhisperKitConfig(
            modelFolder: modelFolder,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )

        whisperKit = try await WhisperKit(config)
        await MainActor.run { progress(1.0) }
    }

    /// Appends `samples` to an internal buffer.  Drains **all** full 5-second
    /// windows (80 000 samples each) through WhisperKit, accumulating their
    /// segments into one array.  Returns an empty array if no full window is
    /// ready yet.
    ///
    /// Call this from your audio-chunk loop:
    /// ```swift
    /// for await chunk in audioCaptureManager.audioChunks {
    ///     let segs = try await transcriptionManager.transcribe(samples: chunk)
    ///     // segs is empty until at least one 5-second window is ready
    /// }
    /// ```
    func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        guard let wk = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        sampleBuffer.append(contentsOf: samples)

        var allSegments: [TranscriptSegment] = []

        while sampleBuffer.count >= Self.windowSize {
            // Take exactly one window; leave the remainder for the next iteration.
            let window = Array(sampleBuffer.prefix(Self.windowSize))
            sampleBuffer.removeFirst(Self.windowSize)

            let results = try await wk.transcribe(audioArray: window)

            let segments = results.flatMap { result in
                result.segments.map { seg in
                    TranscriptSegment(
                        id: UUID(),
                        text: seg.text,
                        startTime: seg.start,
                        endTime: seg.end
                    )
                }
            }
            allSegments.append(contentsOf: segments)
        }

        return allSegments
    }

    /// Flushes whatever remains in the buffer (< 5 s) through WhisperKit.
    /// Call this when recording stops to capture the tail of the audio.
    ///
    /// Throws `TranscriptionError.modelNotLoaded` if the model has not been
    /// loaded, matching the behaviour of `transcribe(samples:)`.
    func flush() async throws -> [TranscriptSegment] {
        guard let wk = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }
        guard !sampleBuffer.isEmpty else { return [] }

        let window = sampleBuffer
        sampleBuffer.removeAll()

        let results = try await wk.transcribe(audioArray: window)

        return results.flatMap { result in
            result.segments.map { seg in
                TranscriptSegment(
                    id: UUID(),
                    text: seg.text,
                    startTime: seg.start,
                    endTime: seg.end
                )
            }
        }
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "WhisperKit model has not been loaded. Call loadModel(size:progress:) first."
        }
    }
}
