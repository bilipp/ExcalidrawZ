//
//  ExcaliDashAuthenticator.swift
//  ExcalidrawZ
//

import CryptoKit
import Foundation
import Security

struct ExcaliDashCredential: Codable, Sendable {
    let accountID: String
    let siteURL: URL
    let apiBaseURL: URL
    /// Nil when the server runs with authentication disabled.
    let identifier: String?
    let password: String?
    /// API key issued by the server's OAuth flow (single sign-on).
    let apiKey: String?
    let userID: String
    let userName: String?
    let email: String?

    var endpoint: ExcaliDashAPIClient.Endpoint {
        .init(siteURL: siteURL, apiBaseURL: apiBaseURL)
    }

    var login: ExcaliDashAPIClient.Login? {
        guard let identifier, let password else { return nil }
        return .init(identifier: identifier, password: password)
    }

    var requiresAuthentication: Bool {
        login != nil || apiKey != nil
    }

    var cloudStorageAccount: CloudStorageAccount {
        let host = siteURL.host() ?? siteURL.absoluteString
        let who = userName ?? email ?? identifier
        return CloudStorageAccount(
            providerID: .excaliDash,
            id: CloudStorageAccountID(rawValue: accountID),
            displayName: who.map { "\(host) · \($0)" } ?? host,
            emailAddress: email
        )
    }
}

struct ExcaliDashCredentialStore: Sendable {
    private let service: String

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.chocoford.excalidraw") {
        self.service = "\(bundleIdentifier).cloud-storage.excalidash"
    }

    func credentials() throws -> [ExcaliDashCredential] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(serviceQuery.merging([
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
        ]) { _, new in new } as CFDictionary, &result)

        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw keychainError(status) }

        let entries: [[String: Any]]
        if let entry = result as? [String: Any] {
            entries = [entry]
        } else {
            entries = result as? [[String: Any]] ?? []
        }
        return entries
            .compactMap { $0[kSecValueData as String] as? Data }
            .compactMap { try? JSONDecoder().decode(ExcaliDashCredential.self, from: $0) }
    }

    func credential(for accountID: CloudStorageAccountID) throws -> ExcaliDashCredential? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery(accountID: accountID).merging([
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]) { _, new in new } as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw keychainError(status)
        }
        return try JSONDecoder().decode(ExcaliDashCredential.self, from: data)
    }

    func save(_ credential: ExcaliDashCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query = baseQuery(accountID: credential.cloudStorageAccount.id)
        let status = SecItemAdd(query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { _, new in new } as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else { throw keychainError(updateStatus) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    func remove(accountID: CloudStorageAccountID) throws {
        let status = SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(accountID: CloudStorageAccountID) -> [String: Any] {
        serviceQuery.merging([
            kSecAttrAccount as String: accountID.rawValue,
        ]) { _, new in new }
    }

    private var serviceQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
#if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
#endif
        return query
    }

    private func keychainError(_ status: OSStatus) -> CloudStorageError {
        let message = SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain error \(status)"
        return .transport("\(message) (OSStatus \(status))")
    }
}

actor ExcaliDashAuthenticator {
    /// The provider and live collaboration share one instance, and thus one
    /// signed-in client per account.
    static let shared = ExcaliDashAuthenticator()

    private let credentialStore: ExcaliDashCredentialStore
    /// One client (and thus one cookie jar / CSRF token) per account, shared
    /// by every session the document store creates for it.
    private var clients: [CloudStorageAccountID: ExcaliDashAPIClient] = [:]

    init(credentialStore: ExcaliDashCredentialStore = ExcaliDashCredentialStore()) {
        self.credentialStore = credentialStore
    }

    func accounts() throws -> [CloudStorageAccount] {
        try credentialStore.credentials().map(\.cloudStorageAccount)
    }

    func authorize(with input: CloudStorageServerCredentials) async throws -> CloudStorageAccount {
        let endpoint = try await ExcaliDashEndpointResolver.resolve(input.serverURL)
        let probe = ExcaliDashAPIClient(endpoint: endpoint, login: nil)
        let status = try await probe.authStatus()
        if status.authOnboardingRequired == true || status.bootstrapRequired == true {
            throw CloudStorageError.invalidProviderResponse(
                "This ExcaliDash server has not been set up yet. Finish the setup in your browser, then connect again."
            )
        }
        if input.useSingleSignOn {
            return try await authorizeWithSingleSignOn(endpoint: endpoint)
        }

        let identifier = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let login: ExcaliDashAPIClient.Login?
        if status.requiresLogin {
            if status.oidcEnforced == true {
                throw CloudStorageError.invalidProviderResponse(
                    "This ExcaliDash server only allows single sign-on. Use “Sign in with SSO” instead."
                )
            }
            guard !identifier.isEmpty, !input.password.isEmpty else {
                throw CloudStorageError.invalidProviderResponse(
                    "Enter your ExcaliDash email or username and password."
                )
            }
            login = .init(identifier: identifier, password: input.password)
        } else {
            login = nil
        }

        let client = ExcaliDashAPIClient(endpoint: endpoint, login: login)
        let user = login == nil ? ExcaliDashUser.anonymous : try await client.signIn()
        let credential = ExcaliDashCredential(
            accountID: Self.accountID(apiBaseURL: endpoint.apiBaseURL, userID: user.id),
            siteURL: endpoint.siteURL,
            apiBaseURL: endpoint.apiBaseURL,
            identifier: login?.identifier,
            password: login?.password,
            apiKey: nil,
            userID: user.id,
            userName: user.name ?? user.username,
            email: user.email
        )
        try credentialStore.save(credential)
        clients[credential.cloudStorageAccount.id] = client
        return credential.cloudStorageAccount
    }

    func credential(for accountID: CloudStorageAccountID) throws -> ExcaliDashCredential {
        guard let credential = try credentialStore.credential(for: accountID) else {
            throw CloudStorageError.authenticationRequired
        }
        return credential
    }

    func client(for credential: ExcaliDashCredential) -> ExcaliDashAPIClient {
        let accountID = credential.cloudStorageAccount.id
        if let client = clients[accountID] { return client }
        let client = ExcaliDashAPIClient(
            endpoint: credential.endpoint,
            login: credential.login,
            apiKey: credential.apiKey
        )
        clients[accountID] = client
        return client
    }

    /// Browser sign-in through the server's OAuth endpoint. The resulting API
    /// key never expires; the user revokes it under Settings → API Keys.
    private func authorizeWithSingleSignOn(
        endpoint: ExcaliDashAPIClient.Endpoint
    ) async throws -> CloudStorageAccount {
        guard let metadata = await ExcaliDashOAuthMetadata.discover(for: endpoint) else {
            throw CloudStorageError.invalidProviderResponse(
                "This ExcaliDash server does not support app sign-in (OAuth). Update ExcaliDash, or sign in with email and password."
            )
        }
        let signIn = await ExcaliDashOAuthSignIn()
        let apiKey = try await signIn.signIn(endpoint: endpoint, metadata: metadata)
        let client = ExcaliDashAPIClient(endpoint: endpoint, login: nil, apiKey: apiKey)
        let user = await Self.identify(client: client, apiKey: apiKey)

        let credential = ExcaliDashCredential(
            accountID: Self.accountID(apiBaseURL: endpoint.apiBaseURL, userID: user.id),
            siteURL: endpoint.siteURL,
            apiBaseURL: endpoint.apiBaseURL,
            identifier: nil,
            password: nil,
            apiKey: apiKey,
            userID: user.id,
            userName: user.name ?? user.username,
            email: user.email
        )
        // Reconnecting the same account replaces its old key.
        try credentialStore.save(credential)
        clients[credential.cloudStorageAccount.id] = client
        return credential.cloudStorageAccount
    }

    /// Who the API key belongs to. `GET /auth/me` accepts API keys only on
    /// servers that allow it; otherwise the owner of the user's own drawings
    /// tells us, and as a last resort the account is keyed per server.
    private static func identify(
        client: ExcaliDashAPIClient,
        apiKey: String
    ) async -> ExcaliDashUser {
        if let data = try? await client.get("auth/me", operation: .authorize),
           let response = try? ExcaliDashAPIClient.decode(ExcaliDashMeResponse.self, from: data) {
            return response.user
        }
        if let data = try? await client.get(
            "drawings",
            query: [URLQueryItem(name: "limit", value: "1")],
            operation: .authorize
        ), let page = try? ExcaliDashAPIClient.decode(ExcaliDashDrawingPage.self, from: data),
           let owner = page.drawings.first, let ownerID = owner.userId {
            return ExcaliDashUser(
                id: ownerID,
                email: nil,
                name: owner.user?.name,
                username: nil,
                mustResetPassword: nil
            )
        }
        return ExcaliDashUser(id: "sso", email: nil, name: nil, username: nil, mustResetPassword: nil)
    }

    func liveContext(
        for accountID: CloudStorageAccountID
    ) throws -> (ExcaliDashCredential, ExcaliDashAPIClient) {
        let credential = try credential(for: accountID)
        return (credential, client(for: credential))
    }

    func signOut(accountID: CloudStorageAccountID) throws {
        clients.removeValue(forKey: accountID)
        try credentialStore.remove(accountID: accountID)
    }

    private static func accountID(apiBaseURL: URL, userID: String) -> String {
        let source = Data("\(apiBaseURL.absoluteString)\n\(userID)".utf8)
        return SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
    }
}
