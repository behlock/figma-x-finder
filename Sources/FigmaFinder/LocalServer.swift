import Foundation
import Network
import BridgeCore

@MainActor
final class LocalServer {
    private var listener: NWListener?
    private let router: Router
    var onRequest: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(store: Store) { router = Router(store: store) }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 17847)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { Task { @MainActor in self?.onFailure?(error.localizedDescription) } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                connection.start(queue: .main)
                self?.receive(connection, buffered: Data())
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { connection.cancel() }
            }
        }
        listener.start(queue: .main)
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let bytes = buffered + (data ?? Data())
                do {
                    if let request = try HTTPRequest.parse(bytes) {
                        let response = self.router.handle(request)
                        if response.status != 401 && request.method != "OPTIONS" { self.onRequest?() }
                        connection.send(content: response.bytes, completion: .contentProcessed { _ in connection.cancel() })
                    } else if complete || error != nil { connection.cancel() }
                    else { self.receive(connection, buffered: bytes) }
                } catch {
                    connection.send(content: HTTPResponse(status: 400).bytes, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }
}
