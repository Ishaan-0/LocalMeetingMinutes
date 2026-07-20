import Foundation

var standardError = FileHandle.standardError
extension FileHandle: TextOutputStream {
    public func write(_ string: String) {
        let data = Data(string.utf8)
        self.write(data)
    }
}

var socketPath: String?
var appBundleID: String?
var listApps = false
var globalManager: ScreenCaptureManager?

var args = CommandLine.arguments.dropFirst()
var it = args.makeIterator()
while let arg = it.next() {
    switch arg {
    case "--socket": socketPath = it.next()
    case "--app-id": appBundleID = it.next()
    case "--list-apps": listApps = true
    default: break
    }
}

if listApps {
    Task {
        do {
            let apps = try await ScreenCaptureManager.listApps()
            for app in apps {
                print("\(app.bundleID)\t\(app.name)")
            }
        } catch {
            fputs("Error listing apps: \(error)\n", stderr)
        }
        exit(0)
    }
} else {
    guard let socket = socketPath, let bundleID = appBundleID else {
        fputs("Usage: AudioCapture --socket <path> --app-id <bundleID>\n       AudioCapture --list-apps\n", stderr)
        exit(1)
    }

    let streamer = SocketStreamer(socketPath: socket)
    let manager = ScreenCaptureManager(streamer: streamer, appBundleID: bundleID)

    Task {
        do {
            try streamer.connect()
            try await manager.start()
        } catch {
            fputs("Failed to start capture: \(error)\n", stderr)
            exit(1)
        }
    }

    // Store manager in a global so signal handlers (C function pointers) can reference it
    globalManager = manager

    signal(SIGTERM) { _ in Task { await globalManager?.stop() } }
    signal(SIGINT)  { _ in Task { await globalManager?.stop() } }

    manager.waitUntilStopped()
}

RunLoop.main.run()
