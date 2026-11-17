//
//  ExcaliDashSocket.swift
//  ExcalidrawZ
//
//  Minimal Socket.IO (protocol v5 over Engine.IO v4, WebSocket transport
//  only) client for ExcaliDash's realtime channel. ExcaliDash relays only a
//  handful of JSON events (join-room, element-update, cursor-move,
//  user-activity, presence-update, error), so no binary packets, namespaces
//  or long-polling fallback are needed.
//

import Foundation
import Logging

actor ExcaliDashSocket {
    // Payloads are freshly decoded JSON, handed over once.
    enum Event: @unchecked Sendable {
        case connected
        case disconnected(reason: String)
        case message(name: String, payload: Any?)
    }

    private let url: URL
    /// Called on every (re)connect: session access tokens live 15 minutes.
    private let tokenProvider: @Sendable () async -> String?
    private let logger = Logger(label: "ExcaliDashSocket")
    private let urlSession: URLSession

    private var task: URLSessionWebSocketTask?
    private var isOpen = false
    private var isClosedByUser = false
    private var nextAckID = 0
    private var acks: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var reconnectAttempt = 0
    private var eventHandler: (@Sendable (Event) async -> Void)?

    /// `siteURL` is the public origin; Socket.IO lives at `/socket.io/`.
    init(siteURL: URL, tokenProvider: @escaping @Sendable () async -> String?) {
        var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false)!
        components.scheme = siteURL.scheme == "http" ? "ws" : "wss"
        components.path = "/socket.io/"
        components.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket"),
        ]
        self.url = components.url!
        self.tokenProvider = tokenProvider
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: configuration)
    }

    deinit {
        urlSession.invalidateAndCancel()
    }

    func setEventHandler(_ handler: @escaping @Sendable (Event) async -> Void) {
        eventHandler = handler
    }

    func connect() {
        isClosedByUser = false
        openTransport()
    }

    func disconnect() {
        isClosedByUser = true
        if isOpen { sendRaw("41") }
        teardown(reason: "client disconnect", notify: false)
    }

    var isConnected: Bool { isOpen }

    /// Fire-and-forget event. Dropped while disconnected, like Socket.IO's
    /// volatile emits; callers resync on reconnect.
    func emit(_ event: String, _ payload: Any) {
        guard isOpen else { return }
        guard let packet = Self.encode(type: "2", ackID: nil, items: [event, payload]) else { return }
        sendRaw(packet)
    }

    /// Event with an acknowledgement callback (e.g. `join-room`).
    func emitWithAck(_ event: String, _ payload: Any, timeout: Duration = .seconds(10)) async throws -> Any? {
        guard isOpen else { throw CloudStorageError.transport("Not connected to ExcaliDash.") }
        let id = nextAckID
        nextAckID += 1
        guard let packet = Self.encode(type: "2", ackID: id, items: [event, payload]) else {
            throw CloudStorageError.invalidProviderResponse("Unable to encode \(event).")
        }
        return try await withCheckedThrowingContinuation { continuation in
            acks[id] = continuation
            sendRaw(packet)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.failAck(id, CloudStorageError.transport("ExcaliDash did not answer \(event)."))
            }
        }
    }

    // MARK: - Transport

    private func openTransport() {
        guard task == nil else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let task = urlSession.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            Task {
                await self.handleReceive(result, task: task)
            }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>, task: URLSessionWebSocketTask) async {
        guard task === self.task else { return }
        switch result {
            case .failure(let error):
                teardown(reason: error.localizedDescription, notify: true)
                scheduleReconnect()
            case .success(let message):
                if case .string(let text) = message {
                    await handleEnginePacket(text)
                }
                if task === self.task { receive(on: task) }
        }
    }

    private func handleEnginePacket(_ text: String) async {
        guard let type = text.first else { return }
        let body = String(text.dropFirst())
        switch type {
            case "0": // open: authenticate into the default namespace
                var auth: [String: Any] = [:]
                if let token = await tokenProvider() { auth["token"] = token }
                let data = (try? JSONSerialization.data(withJSONObject: auth)) ?? Data("{}".utf8)
                sendRaw("40" + String(decoding: data, as: UTF8.self))
            case "2": // ping
                sendRaw("3")
            case "1": // close
                teardown(reason: "server closed", notify: true)
                scheduleReconnect()
            case "4":
                await handleSocketPacket(body)
            default:
                break
        }
    }

    private func handleSocketPacket(_ packet: String) async {
        guard let type = packet.first else { return }
        var rest = Substring(packet.dropFirst())
        // Optional namespace ("/ns,") is never used by ExcaliDash.
        if rest.hasPrefix("/"), let comma = rest.firstIndex(of: ",") {
            rest = rest[rest.index(after: comma)...]
        }
        let digits = rest.prefix { $0.isNumber }
        let ackID = Int(digits)
        rest = rest.dropFirst(digits.count)
        let json = rest.isEmpty ? nil : try? JSONSerialization.jsonObject(
            with: Data(rest.utf8), options: [.fragmentsAllowed]
        )

        switch type {
            case "0": // CONNECT ok
                isOpen = true
                reconnectAttempt = 0
                await eventHandler?(.connected)
            case "4": // CONNECT_ERROR
                let message = (json as? [String: Any])?["message"] as? String ?? "Connection refused"
                logger.warning("ExcaliDash socket refused: \(message)")
                teardown(reason: message, notify: true)
                if message.localizedCaseInsensitiveContains("api key") {
                    // Revoked credentials will not recover by retrying.
                    isClosedByUser = true
                } else {
                    scheduleReconnect()
                }
            case "1": // DISCONNECT from server
                teardown(reason: "server disconnect", notify: true)
                scheduleReconnect()
            case "2": // EVENT
                guard let items = json as? [Any], let name = items.first as? String else { return }
                await eventHandler?(.message(name: name, payload: items.count > 1 ? items[1] : nil))
            case "3": // ACK
                guard let ackID, let continuation = acks.removeValue(forKey: ackID) else { return }
                let items = json as? [Any]
                continuation.resume(returning: items?.first)
            default:
                break
        }
    }

    private func sendRaw(_ text: String) {
        task?.send(.string(text)) { [weak self] error in
            guard let error, let self else { return }
            Task { await self.logSendError(error) }
        }
    }

    private func logSendError(_ error: Error) {
        logger.debug("ExcaliDash socket send failed: \(error.localizedDescription)")
    }

    private func failAck(_ id: Int, _ error: Error) {
        acks.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func teardown(reason: String, notify: Bool) {
        let wasOpen = isOpen
        isOpen = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        for (_, continuation) in acks {
            continuation.resume(throwing: CloudStorageError.transport("Disconnected from ExcaliDash."))
        }
        acks.removeAll()
        if notify, wasOpen {
            let handler = eventHandler
            Task { await handler?(.disconnected(reason: reason)) }
        }
    }

    private func scheduleReconnect() {
        guard !isClosedByUser else { return }
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 5))) * 0.5)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.reconnectIfNeeded()
        }
    }

    private func reconnectIfNeeded() {
        guard !isClosedByUser, task == nil else { return }
        openTransport()
    }

    // MARK: - Encoding

    private static func encode(type: String, ackID: Int?, items: [Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(items),
              let data = try? JSONSerialization.data(withJSONObject: items) else { return nil }
        return "4" + type + (ackID.map(String.init) ?? "") + String(decoding: data, as: UTF8.self)
    }
}
