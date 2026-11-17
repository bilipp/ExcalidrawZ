//
//  ExcaliDashCloudStorageProvider.swift
//  ExcalidrawZ
//

import Foundation
import Logging

struct ExcaliDashCloudStorageProvider: CloudStorageProvider {
    let descriptor = CloudStorageProviderDescriptor(
        id: .excaliDash,
        displayName: "ExcaliDash",
        capabilities: .readWrite,
        connectionMethod: .serverCredentials
    )

    private let authenticator: ExcaliDashAuthenticator
    private let logger = Logger(label: "ExcaliDashCloudStorageProvider")

    init(authenticator: ExcaliDashAuthenticator) {
        self.authenticator = authenticator
    }

    func authorizationStatus() async -> CloudStorageAuthorizationStatus {
        do {
            let accounts = try await authenticator.accounts()
            return accounts.isEmpty ? .signedOut : .signedIn(accounts: accounts)
        } catch {
            logger.error("Unable to restore ExcaliDash authorization status: \(error)")
            return .unknown
        }
    }

    func authorize() async throws -> CloudStorageAccount {
        throw CloudStorageError.authenticationRequired
    }

    func authorize(
        using connectionInput: CloudStorageConnectionInput?
    ) async throws -> CloudStorageAccount {
        guard case .serverCredentials(let credentials) = connectionInput else {
            throw CloudStorageError.authenticationRequired
        }
        return try await authenticator.authorize(with: credentials)
    }

    /// The whole server is the location: after signing in the user lands on
    /// every collection and drawing without picking a folder first.
    func selectLocation(
        for account: CloudStorageAccount?,
        using connectionInput: CloudStorageConnectionInput?
    ) async throws -> CloudStorageLocationSelection {
        let account: CloudStorageAccount = if let connectionInput {
            try await authorize(using: connectionInput)
        } else if let account {
            account
        } else {
            try await authorize()
        }
        let session = try await makeSession(for: account)
        return .selected(account: account, folder: try await session.rootItem())
    }

    func makeSession(for account: CloudStorageAccount) async throws -> any CloudStorageSession {
        guard account.providerID == descriptor.id else {
            throw CloudStorageError.accountUnavailable(account.id)
        }
        let credential = try await authenticator.credential(for: account.id)
        return ExcaliDashCloudStorageSession(
            account: account,
            credential: credential,
            client: await authenticator.client(for: credential)
        )
    }

    func signOut(accountID: CloudStorageAccountID) async throws {
        try await authenticator.signOut(accountID: accountID)
    }
}
