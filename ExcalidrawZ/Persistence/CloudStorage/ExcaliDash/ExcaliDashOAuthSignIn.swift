//
//  ExcaliDashOAuthSignIn.swift
//  ExcalidrawZ
//
//  Single sign-on for ExcaliDash.
//
//  ExcaliDash's SSO (OIDC) is a cookie flow built for its own web app, and
//  identity providers such as Google refuse to sign in inside embedded web
//  views. ExcaliDash also runs an OAuth 2.1 authorization server (dynamic
//  client registration, PKCE, public clients) whose access token is an
//  ordinary ExcaliDash API key. That is what the app uses:
//
//  1. Open a loopback listener on 127.0.0.1 (the only non-Claude redirect URIs
//     ExcaliDash accepts, per RFC 8252).
//  2. Register a client for that redirect URI.
//  3. Show the server's consent page in the system browser sheet. The user
//     signs in there with whatever the server offers (Google, Entra, password).
//  4. Catch the redirect on the listener and trade the code for the key.
//

import AuthenticationServices
import CryptoKit
import Foundation
import Logging
import Network

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct ExcaliDashOAuthMetadata: Decodable, Sendable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL

    enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
    }

    /// Nil when the server predates app sign-in.
    static func discover(for endpoint: ExcaliDashAPIClient.Endpoint) async -> ExcaliDashOAuthMetadata? {
        let candidates = [
            endpoint.siteURL.appending(path: ".well-known/oauth-authorization-server"),
            endpoint.apiBaseURL.appending(path: ".well-known/oauth-authorization-server"),
        ]
        for url in candidates {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.requireFreshCloudStorageResponse(forHTTPMethod: "GET")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let metadata = try? JSONDecoder().decode(Self.self, from: data) else {
                continue
            }
            return metadata
        }
        return nil
    }
}

@MainActor
final class ExcaliDashOAuthSignIn: NSObject {
    private static let clientName = "ExcalidrawZ"
    /// Never navigated to; the code arrives on the loopback listener.
    private static let unusedCallbackScheme = "excalidrawz-excalidash"

    private let logger = Logger(label: "ExcaliDashOAuthSignIn")
    private var authenticationSession: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URLComponents, Error>?
    /// Replaces the browser sheet; used by tests that approve the consent
    /// page themselves.
    var openAuthorizationURL: (@MainActor (URL) -> Void)?

    /// Runs the whole flow and returns the access token (an `exd_` API key).
    func signIn(
        endpoint: ExcaliDashAPIClient.Endpoint,
        metadata: ExcaliDashOAuthMetadata
    ) async throws -> String {
        let server = try ExcaliDashLoopbackServer()
        defer { server.stop() }
        let port = try await server.start { [weak self] components in
            Task { @MainActor in self?.finish(.success(components)) }
        }
        let redirectURI = "http://127.0.0.1:\(port)/callback"

        let clientID = try await registerClient(metadata: metadata, redirectURI: redirectURI)
        let verifier = Self.randomURLSafeString(byteCount: 48)
        let state = Self.randomURLSafeString(byteCount: 24)

        guard var components = URLComponents(
            url: metadata.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw CloudStorageError.invalidProviderResponse("Invalid ExcaliDash authorization URL.")
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: "drawings:read drawings:write collections:read collections:write"),
        ]
        guard let authorizationURL = components.url else {
            throw CloudStorageError.invalidProviderResponse("Invalid ExcaliDash authorization URL.")
        }

        let callback = try await presentAuthorization(authorizationURL)
        let parameters = Dictionary(
            (callback.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        guard parameters["state"] == state else {
            throw CloudStorageError.invalidProviderResponse("ExcaliDash sign-in returned an unexpected state. Try again.")
        }
        if let error = parameters["error"] {
            if error == "access_denied" { throw CloudStorageError.authorizationCancelled }
            throw CloudStorageError.invalidProviderResponse(
                parameters["error_description"] ?? "ExcaliDash sign-in failed (\(error))."
            )
        }
        guard let code = parameters["code"], !code.isEmpty else {
            throw CloudStorageError.invalidProviderResponse("ExcaliDash sign-in returned no authorization code.")
        }
        return try await exchange(
            code: code,
            verifier: verifier,
            clientID: clientID,
            redirectURI: redirectURI,
            metadata: metadata
        )
    }

    // MARK: - Browser

    private func presentAuthorization(_ url: URL) async throws -> URLComponents {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if let openAuthorizationURL {
                    openAuthorizationURL(url)
                    return
                }
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: Self.unusedCallbackScheme
                ) { [weak self] _, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error = error as? ASWebAuthenticationSessionError,
                           error.code == .canceledLogin {
                            self.finish(.failure(CloudStorageError.authorizationCancelled))
                        } else {
                            self.finish(.failure(CloudStorageError.transport(
                                error?.localizedDescription ?? "ExcaliDash sign-in did not finish."
                            )))
                        }
                    }
                }
                session.presentationContextProvider = self
                // Reuse the browser's existing IdP session (e.g. Google).
                session.prefersEphemeralWebBrowserSession = false
                authenticationSession = session
                if !session.start() {
                    finish(.failure(CloudStorageError.transport("Unable to open the ExcaliDash sign-in page.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func finish(_ result: Result<URLComponents, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let session = authenticationSession
        authenticationSession = nil
        // Closing the sheet reports `canceledLogin`, which `continuation`
        // being nil now swallows.
        session?.cancel()
        continuation.resume(with: result)
    }

    // MARK: - OAuth endpoints

    private func registerClient(metadata: ExcaliDashOAuthMetadata, redirectURI: String) async throws -> String {
        var request = URLRequest(url: metadata.registrationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": Self.clientName,
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let data = try await perform(request, step: "client registration")
        struct Registration: Decodable { let client_id: String }
        guard let registration = try? JSONDecoder().decode(Registration.self, from: data) else {
            throw CloudStorageError.invalidProviderResponse("ExcaliDash returned an invalid client registration.")
        }
        return registration.client_id
    }

    private func exchange(
        code: String,
        verifier: String,
        clientID: String,
        redirectURI: String,
        metadata: ExcaliDashOAuthMetadata
    ) async throws -> String {
        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B").utf8)
        let data = try await perform(request, step: "token exchange")
        struct Token: Decodable { let access_token: String }
        guard let token = try? JSONDecoder().decode(Token.self, from: data),
              token.access_token.hasPrefix("exd_") else {
            throw CloudStorageError.invalidProviderResponse("ExcaliDash returned an invalid access token.")
        }
        logger.info("Signed in to ExcaliDash via OAuth")
        return token.access_token
    }

    private func perform(_ request: URLRequest, step: String) async throws -> Data {
        var request = request
        request.timeoutInterval = 30
        request.requireFreshCloudStorageResponse(forHTTPMethod: request.httpMethod ?? "POST")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudStorageError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct OAuthError: Decodable { let error: String?; let error_description: String? }
            let detail = (try? JSONDecoder().decode(OAuthError.self, from: data))
                .flatMap { $0.error_description ?? $0.error }
            throw CloudStorageError.invalidProviderResponse(
                "ExcaliDash \(step) failed: \(detail ?? "HTTP \(status)")"
            )
        }
        return data
    }

    // MARK: - PKCE

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension ExcaliDashOAuthSignIn: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
#if os(macOS)
            NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) ?? NSWindow()
#else
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? UIWindow()
#endif
        }
    }
}

/// Minimal HTTP listener on 127.0.0.1 that waits for `GET /callback?...`.
final class ExcaliDashLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ExcaliDashLoopbackServer")
    private var onCallback: (@Sendable (URLComponents) -> Void)?
    private var didReceiveCallback = false
    private var didReportStart = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw CloudStorageError.transport("Unable to start the sign-in listener: \(error.localizedDescription)")
        }
    }

    /// Starts listening and returns the bound port.
    func start(onCallback: @escaping @Sendable (URLComponents) -> Void) async throws -> UInt16 {
        queue.sync { self.onCallback = onCallback }
        return try await withCheckedThrowingContinuation { continuation in
            // Runs on `queue`, so the one-shot flag needs no further locking.
            listener.stateUpdateHandler = { [weak self, listener] state in
                guard let self, !self.didReportStart else { return }
                switch state {
                    case .ready:
                        guard let port = listener.port?.rawValue else { return }
                        self.didReportStart = true
                        continuation.resume(returning: port)
                    case .failed(let error):
                        self.didReportStart = true
                        continuation.resume(throwing: CloudStorageError.transport(
                            "Unable to start the sign-in listener: \(error.localizedDescription)"
                        ))
                    case .cancelled:
                        self.didReportStart = true
                        continuation.resume(throwing: CancellationError())
                    default:
                        break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete || error != nil || buffer.count > 64 * 1024 {
                self.respond(on: connection, request: buffer)
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection, request: Data) {
        let requestLine = String(decoding: request.prefix(4096), as: UTF8.self)
            .split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : ""
        let components = URLComponents(string: "http://127.0.0.1\(target)")

        let status: String
        let body: String
        if parts.first == "GET", let components, components.path == "/callback" {
            status = "200 OK"
            let failed = components.queryItems?.contains(where: { $0.name == "error" }) == true
            body = Self.page(
                title: failed ? "Sign-in was not completed" : "Signed in to ExcaliDash",
                message: failed
                    ? "You can close this window and try again in ExcalidrawZ."
                    : "You can close this window and return to ExcalidrawZ."
            )
            if !didReceiveCallback {
                didReceiveCallback = true
                onCallback?(components)
            }
        } else {
            status = "404 Not Found"
            body = Self.page(title: "Not found", message: "")
        }

        let response = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
            + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width, initial-scale=1">\
        <title>\(title)</title><style>body{font:16px -apple-system,system-ui,sans-serif;\
        display:flex;min-height:90vh;align-items:center;justify-content:center;text-align:center;\
        color:#222;background:#fafafa}@media(prefers-color-scheme:dark){body{color:#eee;background:#1e1e1e}}\
        </style></head><body><div><h2>\(title)</h2><p>\(message)</p></div></body></html>
        """
    }
}
