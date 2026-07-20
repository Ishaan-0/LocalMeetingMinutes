import Accelerate
import AVFoundation
import ScreenCaptureKit

/// Captures system audio (via ScreenCaptureKit) and microphone (via AVAudioEngine),
/// mixes them by summing (clamped to [-1, 1]), and delivers 100 ms chunks
/// (1 600 Float32 samples at 16 kHz) via `audioChunks`.
final class AudioCaptureManager: NSObject, @unchecked Sendable {

    // MARK: - Public

    /// Delivers 1 600-sample (100 ms @ 16 kHz) mono Float32 chunks.
    let audioChunks: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation

    // MARK: - Private

    private let chunkSize: Int = 1_600          // 100 ms × 16 000 Hz
    private let targetRate: Double = 16_000

    // Separate staging buffers for each source — protected by stagingLock
    private var systemStagingBuffer: [Float] = []
    private var micStagingBuffer: [Float] = []
    private let stagingLock = NSLock()

    // SCStream
    private var scStream: SCStream?

    // AVAudioEngine
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    // MARK: - Init

    override init() {
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        audioChunks = stream
        continuation = cont
        super.init()
    }

    // MARK: - Public API

    /// Requests microphone permission, then starts both capture sources.
    func start() async throws {
        try await requestMicrophonePermission()
        try await startSystemAudio()
        try startMicrophone()
    }

    /// Stops both capture sources and finishes the stream.
    func stop() {
        engine.stop()
        let stream = scStream
        scStream = nil
        Task {
            try? await stream?.stopCapture()
        }
        continuation.finish()
    }

    // MARK: - Permission

    private func requestMicrophonePermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                throw CaptureError.microphonePermissionDenied
            }
        case .denied, .restricted:
            throw CaptureError.microphonePermissionDenied
        @unknown default:
            throw CaptureError.microphonePermissionDenied
        }
    }

    // MARK: - System Audio (ScreenCaptureKit)

    private func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw CaptureError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio               = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate                  = Int(targetRate)
        config.channelCount                = 1
        // Minimise video overhead
        config.width  = 2
        config.height = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: .global(qos: .userInteractive)
        )
        try await stream.startCapture()
        scStream = stream
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicrophone() throws {
        let inputNode   = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CaptureError.audioFormatCreationFailed
        }

        guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.audioConverterCreationFailed
        }
        converter = conv

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer, outputFormat: outputFormat)
        }

        try engine.start()
    }

    private func handleMicBuffer(_ inputBuffer: AVAudioPCMBuffer,
                                 outputFormat: AVAudioFormat) {
        guard let conv = converter else { return }

        let inputFrames  = inputBuffer.frameLength
        let ratio        = targetRate / inputBuffer.format.sampleRate
        let outputFrames = AVAudioFrameCount(Double(inputFrames) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrames
        ) else { return }

        var convError: NSError?
        var inputConsumed = false

        conv.convert(to: outputBuffer, error: &convError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard convError == nil else { return }
        appendAndDrain(pcmBufferToFloats(outputBuffer), source: .mic)
    }

    // MARK: - Mix + Deliver

    private enum AudioSource { case system, mic }

    /// Appends new samples to the appropriate staging buffer, then emits mixed
    /// chunks whenever both buffers contain at least `chunkSize` samples.
    private func appendAndDrain(_ samples: [Float], source: AudioSource) {
        stagingLock.lock()
        switch source {
        case .system: systemStagingBuffer.append(contentsOf: samples)
        case .mic:    micStagingBuffer.append(contentsOf: samples)
        }

        while systemStagingBuffer.count >= chunkSize && micStagingBuffer.count >= chunkSize {
            let sysChunk = Array(systemStagingBuffer.prefix(chunkSize))
            let micChunk = Array(micStagingBuffer.prefix(chunkSize))
            systemStagingBuffer.removeFirst(chunkSize)
            micStagingBuffer.removeFirst(chunkSize)

            stagingLock.unlock()

            // Sum with vDSP_vadd, then clamp to [-1, 1] with vDSP_vclip
            var mixed = [Float](repeating: 0, count: chunkSize)
            vDSP_vadd(sysChunk, 1, micChunk, 1, &mixed, 1, vDSP_Length(chunkSize))

            var low: Float  = -1.0
            var high: Float =  1.0
            vDSP_vclip(mixed, 1, &low, &high, &mixed, 1, vDSP_Length(chunkSize))

            continuation.yield(mixed)

            stagingLock.lock()
        }
        stagingLock.unlock()
    }

    // MARK: - Helpers

    private func pcmBufferToFloats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }

    private func extractFloats(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        ) == noErr, let ptr = dataPointer else { return nil }

        let floatCount = length / MemoryLayout<Float>.size
        return ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { fptr in
            Array(UnsafeBufferPointer(start: fptr, count: floatCount))
        }
    }
}

// MARK: - SCStreamOutput

extension AudioCaptureManager: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard let samples = extractFloats(from: sampleBuffer) else { return }
        appendAndDrain(samples, source: .system)
    }
}

// MARK: - Errors

enum CaptureError: LocalizedError {
    case microphonePermissionDenied
    case noDisplayFound
    case audioFormatCreationFailed
    case audioConverterCreationFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone."
        case .noDisplayFound:
            return "No display found for ScreenCaptureKit audio capture."
        case .audioFormatCreationFailed:
            return "Failed to create 16 kHz mono audio format for resampling."
        case .audioConverterCreationFailed:
            return "Failed to create AVAudioConverter for microphone resampling."
        }
    }
}
