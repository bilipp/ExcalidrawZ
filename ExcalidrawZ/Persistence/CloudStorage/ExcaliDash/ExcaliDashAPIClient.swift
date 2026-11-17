//
//  ExcaliDashAPIClient.swift
//  ExcalidrawZ
//
//  HTTP client for a self-hosted ExcaliDash server.
//
//  ExcaliDash authenticates browser-style: `POST /auth/login` sets HttpOnly
//  access/refresh cookies, and every mutation (login included) must carry an
//  `x-csrf-token` header bound to the `excalidash-csrf-client` cookie. The
//  client therefore owns an ephemeral URLSession whose in-memory cookie jar
//  lives exactly as long as this actor. When the access token expires it
//  refreshes once, and when the refresh token is gone (app relaunch, 7 day
//  expiry, rotation) it logs in again with the Keychain credential.
//

import Foundation
import Logging

actor ExcaliDashAPIClient {
    struct Endpoint: Sendable {
        /// Public site origin, used for editor links.
        let siteURL: URL
        /// REST base. `siteURL/api` behind the bundled nginx, or the backend
        /// itself when the user pointed the app straight at it.
        let apiBaseURL: URL
    }

    struct Login: Sendable {
        let identifier: String
        let password: String
    }

    let endpoint: Endpoint
    private let login: Login?
    /// API key from the OAuth (single sign-on) flow. Sent as a Bearer token;
    /// such requests need neither cookies nor CSRF tokens.
    private let apiKey: String?
    private let urlSession: URLSession
    private let logger = Logger(label: "ExcaliDashAPIClient")

    private var csrfToken: String?
    private var authenticationTask: Task<Void, Error>?
    private var hasAuthenticated = false

    init(endpoint: Endpoint, login: Login?, apiKey: String? = nil) {
        self.endpoint = endpoint
        self.login = login
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        self.urlSession = URLSession(configuration: configuration)
    }

    deinit {
        urlSession.invalidateAndCancel()
    }

    // MARK: - Public API

    func authStatus() async throws -> ExcaliDashAuthStatus {
        let data = try await send(
            "GET", "auth/status",
            operation: .authorize,
            authenticate: false
        )
        return try Self.decode(ExcaliDashAuthStatus.self, from: data)
    }

    /// Logs in and returns the signed-in user. Used while connecting, before
    /// the credential is stored.
    func signIn() async throws -> ExcaliDashUser {
        guard let login else { throw CloudStorageError.authenticationRequired }
        let user = try await performLogin(login)
        hasAuthenticated = true
        return user
    }

    func get(
        _ path: String,
        query: [URLQueryItem] = [],
        operation: CloudStorageOperation
    ) async throws -> Data {
        try await send("GET", path, query: query, operation: operation)
    }

    func send(
        _ method: String,
        _ path: String,
        json: Any,
        operation: CloudStorageOperation
    ) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await send(
            method, path,
            body: body,
            contentType: "application/json",
            operation: operation
        )
    }

    func delete(_ path: String, operation: CloudStorageOperation) async throws {
        _ = try await send("DELETE", path, operation: operation)
    }

    /// Fetches binary content addressed by an absolute URL or by a server
    /// path such as `/api/files/<drawing>/<file>` stored in a scene.
    func fetchAsset(_ reference: String) async throws -> (Data, String?) {
        let url = try resolveAssetURL(reference)
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let apiKey, url.host() == endpoint.apiBaseURL.host() {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var (data, response) = try await perform(request)
        if response.statusCode == 401, login != nil {
            try await reauthenticate()
            (data, response) = try await perform(request)
        }
        try Self.validate(response, data: data, operation: .download, itemPath: url.path)
        return (data, response.mimeType)
    }

    // MARK: - Core request pipeline

    private func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        operation: CloudStorageOperation,
        authenticate: Bool = true
    ) async throws -> Data {
        let isMutation = method != "GET"
        if authenticate, login != nil, !hasAuthenticated {
            try await reauthenticate()
        }

        var didRefreshCSRF = false
        var didReauthenticate = false
        while true {
            var request = URLRequest(url: url(for: path, query: query))
            request.httpMethod = method
            request.httpBody = body
            if let contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            request.requireFreshCloudStorageResponse(forHTTPMethod: method)
            if let apiKey {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            } else if isMutation {
                request.setValue(try await currentCSRFToken(), forHTTPHeaderField: "x-csrf-token")
            }

            let (data, response) = try await perform(request)

            if response.statusCode == 403, isMutation, !didRefreshCSRF,
               Self.errorPayload(data)?.error?.localizedCaseInsensitiveContains("csrf") == true {
                csrfToken = nil
                didRefreshCSRF = true
                continue
            }
            if response.statusCode == 401, authenticate, login != nil, !didReauthenticate {
                didReauthenticate = true
                try await reauthenticate()
                continue
            }
            try Self.validate(response, data: data, operation: operation, itemPath: path)
            return data
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CloudStorageError.invalidProviderResponse("ExcaliDash returned a non-HTTP response.")
            }
            return (data, http)
        } catch let error as CloudStorageError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as Foundation.URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CloudStorageError.transport(error.localizedDescription)
        }
    }

    private func url(for path: String, query: [URLQueryItem]) -> URL {
        var url = endpoint.apiBaseURL.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        return url
    }

    private func resolveAssetURL(_ reference: String) throws -> URL {
        if reference.hasPrefix("http://") || reference.hasPrefix("https://") {
            guard let url = URL(string: reference) else {
                throw CloudStorageError.invalidProviderResponse("Invalid asset URL \(reference)")
            }
            return url
        }
        // Scene refs are always public paths (`/api/files/...`), even when the
        // app talks to the backend directly where routes have no `/api` prefix.
        var path = reference
        if path.hasPrefix("/api/") {
            path.removeFirst("/api/".count)
        } else if path.hasPrefix("/") {
            path.removeFirst()
        }
        return endpoint.apiBaseURL.appending(path: path)
    }

    // MARK: - CSRF & authentication

    private func currentCSRFToken() async throws -> String {
        if let csrfToken { return csrfToken }
        var request = URLRequest(url: url(for: "csrf-token", query: []))
        request.requireFreshCloudStorageResponse(forHTTPMethod: "GET")
        let (data, response) = try await perform(request)
        try Self.validate(response, data: data, operation: .authorize, itemPath: "csrf-token")
        let token = try Self.decode(ExcaliDashCSRFToken.self, from: data).token
        csrfToken = token
        return token
    }

    /// Serialized: refresh tokens are single-use under rotation, so two
    /// concurrent refreshes would revoke each other.
    private func reauthenticate() async throws {
        if let authenticationTask {
            return try await authenticationTask.value
        }
        let task = Task { try await self.refreshOrLogin() }
        authenticationTask = task
        defer { authenticationTask = nil }
        try await task.value
        hasAuthenticated = true
    }

    private func refreshOrLogin() async throws {
        guard let login else { return }
        if hasAuthenticated {
            var request = URLRequest(url: url(for: "auth/refresh", query: []))
            request.httpMethod = "POST"
            request.setValue(try await currentCSRFToken(), forHTTPHeaderField: "x-csrf-token")
            if let (_, response) = try? await perform(request),
               (200..<300).contains(response.statusCode) {
                return
            }
        }
        _ = try await performLogin(login)
    }

    private func performLogin(_ login: Login) async throws -> ExcaliDashUser {
        var didRefreshCSRF = false
        while true {
            var request = URLRequest(url: url(for: "auth/login", query: []))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(try await currentCSRFToken(), forHTTPHeaderField: "x-csrf-token")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "identifier": login.identifier,
                "password": login.password,
            ])
            let (data, response) = try await perform(request)
            let payload = Self.errorPayload(data)

            switch response.statusCode {
                case 200..<300:
                    let user = try Self.decode(ExcaliDashLoginResponse.self, from: data).user
                    if user.mustResetPassword == true {
                        throw CloudStorageError.invalidProviderResponse(
                            "This ExcaliDash account must change its password. Sign in on the website first, then connect again."
                        )
                    }
                    logger.info("Signed in to ExcaliDash at \(endpoint.siteURL.host() ?? "")")
                    return user
                case 403 where payload?.error?.localizedCaseInsensitiveContains("csrf") == true && !didRefreshCSRF:
                    csrfToken = nil
                    didRefreshCSRF = true
                    continue
                case 401:
                    throw CloudStorageError.invalidProviderResponse(
                        payload?.message ?? "Invalid email or password."
                    )
                case 403:
                    throw CloudStorageError.invalidProviderResponse(
                        "This ExcaliDash server only allows single sign-on. Use “Sign in with SSO” instead."
                    )
                case 404:
                    // Authentication is disabled on the server; nothing to do.
                    return ExcaliDashUser.anonymous
                case 409:
                    throw CloudStorageError.invalidProviderResponse(
                        "This ExcaliDash server has not been set up yet. Finish the setup in your browser, then connect again."
                    )
                case 429:
                    throw CloudStorageError.rateLimited(retryAfter: Self.retryAfter(response))
                default:
                    throw CloudStorageError.transport(
                        payload?.message ?? "ExcaliDash login failed with HTTP \(response.statusCode)."
                    )
            }
        }
    }

    // MARK: - Helpers

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try ExcaliDashJSON.decoder.decode(type, from: data)
        } catch {
            throw CloudStorageError.invalidProviderResponse(
                "Unexpected ExcaliDash response (\(T.self)): \(error.localizedDescription)"
            )
        }
    }

    private static func errorPayload(_ data: Data) -> ExcaliDashErrorPayload? {
        try? JSONDecoder().decode(ExcaliDashErrorPayload.self, from: data)
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
    }

    private static func validate(
        _ response: HTTPURLResponse,
        data: Data,
        operation: CloudStorageOperation,
        itemPath: String
    ) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let payload = errorPayload(data)
        switch response.statusCode {
            case 401:
                throw CloudStorageError.authenticationRequired
            case 403 where payload?.code == "MUST_RESET_PASSWORD":
                throw CloudStorageError.invalidProviderResponse(
                    "This ExcaliDash account must change its password on the website."
                )
            case 403:
                throw CloudStorageError.permissionDenied(operation)
            case 404:
                throw CloudStorageError.itemNotFound(CloudStorageItemID(rawValue: itemPath))
            case 409 where payload?.code == "AUTH_ONBOARDING_REQUIRED":
                throw CloudStorageError.invalidProviderResponse(
                    "This ExcaliDash server has not been set up yet. Finish the setup in your browser."
                )
            case 409:
                throw CloudStorageError.conflict
            case 413:
                throw CloudStorageError.transport(
                    payload?.message ?? "The drawing is too large for this ExcaliDash server."
                )
            case 429:
                throw CloudStorageError.rateLimited(retryAfter: retryAfter(response))
            default:
                let detail = payload?.message ?? payload?.error ?? "HTTP \(response.statusCode)"
                throw CloudStorageError.transport("ExcaliDash \(operation.rawValue) failed: \(detail)")
        }
    }
}

/// Resolves the REST base for a user-entered server URL.
enum ExcaliDashEndpointResolver {
    static func resolve(_ input: URL) async throws -> ExcaliDashAPIClient.Endpoint {
        let siteURL = try normalizedSiteURL(input)
        var candidates = [siteURL.appending(path: "api"), siteURL]
        // Users frequently paste an editor or dashboard link.
        if siteURL.path().hasSuffix("/api") {
            candidates = [siteURL]
        }
        var lastError: Error?
        for apiBase in candidates {
            do {
                if try await isExcaliDashAPI(apiBase) {
                    let site = apiBase.lastPathComponent == "api"
                        ? apiBase.deletingLastPathComponent()
                        : apiBase
                    return .init(siteURL: site, apiBaseURL: apiBase)
                }
            } catch {
                lastError = error
            }
        }
        if let lastError = lastError as? CloudStorageError, case .transport = lastError {
            throw lastError
        }
        throw CloudStorageError.invalidProviderResponse(
            "No ExcaliDash server was found at \(siteURL.absoluteString)."
        )
    }

    static func normalizedSiteURL(_ input: URL) throws -> URL {
        var string = input.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !string.contains("://") { string = "https://" + string }
        guard var components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else {
            throw CloudStorageError.invalidProviderResponse("Enter a valid ExcaliDash server URL.")
        }
        components.query = nil
        components.fragment = nil
        // Drop app routes such as /editor/<id> or /collections.
        let path = components.path
        if let range = path.range(of: "/editor/") ?? path.range(of: "/collections")
            ?? path.range(of: "/shared/") ?? path.range(of: "/login") {
            components.path = String(path[..<range.lowerBound])
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else {
            throw CloudStorageError.invalidProviderResponse("Enter a valid ExcaliDash server URL.")
        }
        return url
    }

    private static func isExcaliDashAPI(_ apiBase: URL) async throws -> Bool {
        var request = URLRequest(url: apiBase.appending(path: "auth/status"))
        request.timeoutInterval = 20
        request.requireFreshCloudStorageResponse(forHTTPMethod: "GET")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudStorageError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        return (try? JSONDecoder().decode(ExcaliDashAuthStatus.self, from: data)) != nil
    }
}
