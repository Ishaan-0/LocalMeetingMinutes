import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreAudio

final class ScreenCaptureManager: NSObject {
    private var stream: SCStream?
    private let streamer: SocketStreamer
    private let appBundleID: String
    private let sampleRate: Double = 16000
    private let semaphore = DispatchSemaphore(value: 0)
    var isRunning = false

    init(streamer: SocketStreamer, appBundleID: String) {
        self.streamer = streamer
        self.appBundleID = appBundleID
    }

    static func listApps() async throws -> [(bundleID: String, name: String)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        var seen = Set<String>()
        var result: [(String, String)] = []
        for app in content.applications {
            let bid = app.bundleIdentifier
            if !seen.contains(bid) {
                seen.insert(bid)
                result.append((bid, app.applicationName))
            }
        }
        return result.sorted { $0.1 < $1.1 }
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let app = content.applications.first(where: { $0.bundleIdentifier == appBundleID }) else {
            throw CaptureError.appNotFound(appBundleID)
        }

        let filter = SCContentFilter(desktopIndependentWindow: content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == appBundleID
        }) ?? content.windows[0])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1

        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
        try await stream?.startCapture()
        isRunning = true
        fputs("Capturing audio from: \(app.applicationName)\n", stderr)
    }

    func stop() async {
        try? await stream?.stopCapture()
        isRunning = false
        semaphore.signal()
    }

    func waitUntilStopped() {
        semaphore.wait()
    }
}

extension ScreenCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard let ptr = dataPointer, length > 0 else { return }

        let data = Data(bytes: ptr, count: length)
        streamer.send(data)
    }
}

enum CaptureError: Error {
    case appNotFound(String)
}
