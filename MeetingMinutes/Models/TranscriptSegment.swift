import Foundation

/// A timestamped text segment produced by the transcription pipeline.
struct TranscriptSegment: Identifiable, Codable {
    let id: UUID
    let text: String
    let startTime: Float
    let endTime: Float
}
