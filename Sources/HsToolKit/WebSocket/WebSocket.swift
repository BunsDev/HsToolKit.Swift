import Foundation
import Combine
import NIO
import NIOHTTP1
import NIOWebSocket

public class WebSocket: NSObject {
    public weak var delegate: IWebSocketDelegate?

    private var cancellables = Set<AnyCancellable>()
    private var logger: Logger?

    private let queue = DispatchQueue(label: "websocket-delegate-queue", qos: .background)
    private let reachabilityManager: ReachabilityManager

    private let url: URL
    private let auth: String?
    private let maxFrameSize: Int

    private var eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var nioWebSocket: INIOWebSocket?
    private var isStarted = false

    private var _state: WebSocketState = .disconnected(error: WebSocketState.DisconnectError.notStarted)
    public var state: WebSocketState {
        get {
            queue.sync {
                _state
            }
        }
        set {
            queue.async { [weak self] in
                self?._state = newValue
                DispatchQueue.global(qos: .utility).async {
                    self?.delegate?.didUpdate(state: newValue)
                }
            }
        }
    }

    public init(url: URL, reachabilityManager: ReachabilityManager, auth: String?, sessionRequestTimeout: TimeInterval = 20,
                maxFrameSize: Int = 1 << 27, logger: Logger? = nil) {
        self.url = url
        self.reachabilityManager = reachabilityManager
        self.auth = auth
        self.maxFrameSize = maxFrameSize
        self.logger = logger

        super.init()

        reachabilityManager.$isReachable
                .sink { [weak self] isReachable in
                    if isReachable {
                        self?.connect()
                    } else {
                        self?.disconnect(code: .normalClosure, error: WebSocketState.DisconnectError.socketDisconnected(reason: .networkNotReachable))
                    }
                }
                .store(in: &cancellables)

        reachabilityManager.connectionTypeChangedPublisher
                .sink { [weak self] in
                    guard case .connected = self?.state else {
                        return
                    }

                    self?.disconnect(code: .normalClosure, error: WebSocketState.DisconnectError.socketDisconnected(reason: .networkNotReachable))
                    self?.connect()
                }
                .store(in: &cancellables)

        BackgroundModeObserver.shared.foregroundFromExpiredBackgroundPublisher
                .sink { [weak self] in
                    self?.disconnect(code: .normalClosure, error: WebSocketState.DisconnectError.socketDisconnected(reason: .appInBackgroundMode))
                    self?.connect()
                }
                .store(in: &cancellables)
    }

    deinit {
        eventLoopGroup.shutdownGracefully { _ in }
    }

    private func connect() {
        guard case .disconnected = state, isStarted else {
            return
        }

        if let socket = nioWebSocket {
            socket.close(code: .normalClosure).whenComplete { [weak self] _ in
                self?.nioWebSocket = nil
                self?.connect()
            }
            return
        }

        state = .connecting
        logger?.debug("Connecting to \(url)")

        var headers = HTTPHeaders()

        if let auth = auth {
            let basicAuth = Data(":\(auth)".utf8).base64EncodedString()
            headers.add(name: "Authorization", value: "Basic \(basicAuth)")
        }

        let configuration = WebSocketClient.Configuration(maxFrameSize: maxFrameSize)
        let nioWebSocket = NIOWebSocket.connect(to: url, headers: headers, configuration: configuration, on: eventLoopGroup) { [weak self] webSocket in
            self?.onConnected(webSocket: webSocket)
        }

        nioWebSocket.whenFailure { [weak self] error in
            self?.logger?.debug("WebSocket connection error: \(error)")
            self?.state = .disconnected(error: error)
        }
    }

    private func disconnect(code: WebSocketErrorCode, error: Error = WebSocketState.DisconnectError.notStarted) {
        logger?.debug("Disconnecting from websocket with code: \(code); error: \(error)")
        nioWebSocket?.close(code: code)
        state = .disconnected(error: error)
    }

    private func onConnected(webSocket: INIOWebSocket) {
        nioWebSocket = webSocket

        webSocket.onClose.whenSuccess { [weak self, weak webSocket] _ in
            guard let lastSocket = webSocket, !lastSocket.waitingForClose else {
                self?.logger?.debug("WebSocket disconnected by client")
                return
            }

            self?.logger?.debug("WebSocket disconnected by server")
            self?.disconnect(code: .unexpectedServerError, error: WebSocketState.DisconnectError.socketDisconnected(reason: .unexpectedServerError))
            self?.connect()
        }

        webSocket.onText { [weak self] _, text in
            self?.logger?.debug("WebSocket Received text: \(text)")
            self?.delegate?.didReceive(text: text)
        }

        webSocket.onBinary { [weak self] _, _ in
            self?.logger?.debug("WebSocket Received data")
        }

        webSocket.onError { [weak self] error in
            self?.logger?.debug("WebSocket Received error: \(error)")
            self?.disconnect(code: .protocolError, error: error)
        }

        logger?.debug("WebSocket connected \(webSocket)")
        state = .connected
    }

    private func verifyConnection() throws {
        switch state {
        case .connected: ()
        case .connecting:
            throw WebSocketStateError.connecting
        case .disconnected(let error):
            guard let disconnectError = error as? WebSocketState.DisconnectError else {
                throw WebSocketStateError.couldNotConnect
            }

            guard case .socketDisconnected(let reason) = disconnectError else {
                throw WebSocketStateError.connecting
            }

            switch reason {
            case .appInBackgroundMode:
                throw WebSocketStateError.connecting
            case .networkNotReachable, .unexpectedServerError:
                throw WebSocketStateError.couldNotConnect
            }
        }

    }

}

extension WebSocket: IWebSocket {

    public var source: String {
        url.host ?? ""
    }

    public func start() {
        isStarted = true
        connect()
    }

    public func stop() {
        isStarted = false
        disconnect(code: .goingAway)
    }

    public func send(data: Data, completionHandler: ((Error?) -> ())?) throws {
        try verifyConnection()

        nioWebSocket?.send(raw: data, opcode: .binary, fin: true, completionHandler: completionHandler)
    }

    public func send(ping: Data) throws {
        try verifyConnection()

        nioWebSocket?.sendPing(promise: nil)
    }

    public func send(pong: Data) throws {
        // URLSessionWebSocketTask has no method to send "pong" message
    }

}
