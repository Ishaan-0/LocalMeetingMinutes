import Foundation
import Network

final class SocketStreamer {
    private let socketPath: String
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.meetingminutes.socket")

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func connect() throws {
        let endpoint = NWEndpoint.unix(path: socketPath)
        let params = NWParameters()
        params.allowLocalEndpointReuse = true
        connection = NWConnection(to: endpoint, using: params)
        connection?.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                fputs("Socket connection failed: \(error)\n", stderr)
            default:
                break
            }
        }
        connection?.start(queue: queue)
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .idempotent)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }
}
