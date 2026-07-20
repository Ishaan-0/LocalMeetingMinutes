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
@MainActor
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
    ///   - progress: Called on the main actor with values in [0, 1] as the
    ///     model components finish loading. WhisperKit does not surface
    ///     granular progress, so we emit 0.0 at start and 1.0 on completion.
    func loadModel(size: WhisperModelSize, progress: @escaping (Double) -> Void) async throws {
        progress(0.0)

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
        progress(1.0)
    }

    /// Appends `samples` to an internal buffer.  When the buffer reaches
    /// 5 seconds (80 000 samples) it is flushed through WhisperKit and the
    /// resulting `TranscriptSegment` array is returned.  Returns an empty
    /// array if the buffer has not yet filled.
    ///
    /// Call this from your audio-chunk loop:
    /// ```swift
    /// for await chunk in audioCaptureManager.audioChunks {
    ///     let segs = try await transcriptionManager.transcribe(samples: chunk)
    ///     // segs is empty until a 5-second window is ready
    /// }
    /// ```
    func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        guard let wk = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        sampleBuffer.append(contentsOf: samples)

        guard sampleBuffer.count >= Self.windowSize else {
            return []
        }

        // Take exactly one window; leave the remainder for the next call.
        let window = Array(sampleBuffer.prefix(Self.windowSize))
        sampleBuffer.removeFirst(Self.windowSize)

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

    /// Flushes whatever remains in the buffer (< 5 s) through WhisperKit.
    /// Call this when recording stops to capture the tail of the audio.
    func flush() async throws -> [TranscriptSegment] {
        guard let wk = whisperKit else { return [] }
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
