//
//  CloudStorageServerConnectionSheet.swift
//  ExcalidrawZ
//

import SwiftUI

struct CloudStorageServerConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let providerID: CloudStorageProviderID
    let providerName: String
    let connectedAccounts: [CloudStorageAccount]
    let onSelectAccount: @MainActor (CloudStorageAccount) async throws -> Void
    let onConnect: @MainActor (CloudStorageServerCredentials) async throws -> Void

    @State private var serverURL = "https://"
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var openingAccountID: CloudStorageAccountID?
    @State private var errorMessage: String?
    @State private var operationTask: Task<Void, Never>?
    /// ExcaliDash: what the server at `serverURL` offers for sign-in.
    @State private var excaliDashSignIn: ExcaliDashSignInOptions?
    @State private var isUsingSingleSignOn = false

    init(
        providerID: CloudStorageProviderID = .webDAV,
        providerName: String,
        connectedAccounts: [CloudStorageAccount] = [],
        onSelectAccount: @escaping @MainActor (CloudStorageAccount) async throws -> Void = { _ in },
        onConnect: @escaping @MainActor (CloudStorageServerCredentials) async throws -> Void
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.connectedAccounts = connectedAccounts
        self.onSelectAccount = onSelectAccount
        self.onConnect = onConnect
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if !isExcaliDash {
                    WebDAVServiceMarqueeHeader()
                }
                header
            }

            Form {
                Section {
                    TextField(String(
                        localized: "cloudStorageServerURL",
                        defaultValue: "Server URL"
                    ), text: $serverURL)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
#endif
                        .autocorrectionDisabled()

                    if showsPasswordFields {
                    TextField(isExcaliDash
                        ? String(
                            localized: "cloudStorageEmailOrUsername",
                            defaultValue: "Email or username"
                        )
                        : String(
                            localized: "cloudStorageUsername",
                            defaultValue: "Username"
                        ), text: $username)
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .autocorrectionDisabled()

                    SecureField(isExcaliDash
                        ? String(localized: "cloudStoragePassword", defaultValue: "Password")
                        : String(
                            localized: "cloudStoragePasswordOrAppPassword",
                            defaultValue: "Password or app password"
                        ), text: $password)
                    }
                } header: {
                    Text(isExcaliDash
                        ? String(
                            localized: "cloudStorageExcaliDashAccount",
                            defaultValue: "ExcaliDash Account"
                        )
                        : String(
                            localized: "cloudStorageWebDAVAccount",
                            defaultValue: "WebDAV Account"
                        ))
                } footer: {
                    VStack(alignment: .leading, spacing: 12) {
                        if !isExcaliDash, let detectedServiceName {
                            Text(String(
                                format: String(
                                    localized: "cloudStorageDetectedServiceFormat",
                                    defaultValue: "Service: %@"
                                ),
                                detectedServiceName
                            ))
                        }
                        if isExcaliDash {
                            Text(String(
                                localized: "cloudStorageExcaliDashCredentialsDescriptionSSO",
                                defaultValue: "Enter the address of your ExcaliDash server, e.g. https://draw.example.com. All collections and drawings appear in the sidebar and every change is saved straight to the server. Sign in with single sign-on, or with email and password (leave both empty if the server has sign-in disabled). Credentials are stored only in this device's Keychain."
                            ))
                        } else {
                        Text(String(
                            localized: "cloudStorageWebDAVCredentialsDescription",
                            defaultValue: "Enter the HTTPS site or WebDAV URL provided by your service. Nextcloud and ownCloud endpoints are discovered automatically. Credentials are stored only in this device's Keychain."
                        ))
                        }

                        if showsPasswordFields {
                        Button {
                            connect()
                        } label: {
                            HStack(spacing: 8) {
                                if isConnecting && !isUsingSingleSignOn {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isConnecting
                                    ? String(
                                        localized: "cloudStorageConnecting",
                                        defaultValue: "Connecting"
                                    )
                                    : String(
                                        localized: "cloudStorageConnect",
                                        defaultValue: "Connect"
                                    )
                                )
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .modernButtonStyle(style: .glassProminent, size: .large, shape: .modern)
                        .disabled(!canConnect || isConnecting)
                        }

                        if isExcaliDash {
                            Button {
                                connect(useSingleSignOn: true)
                            } label: {
                                HStack(spacing: 8) {
                                    if isConnecting && isUsingSingleSignOn {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "person.badge.key.fill")
                                    }
                                    Text(singleSignOnTitle)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .modernButtonStyle(
                                style: showsPasswordFields ? .glass : .glassProminent,
                                size: .large,
                                shape: .modern
                            )
                            .disabled(!hasServerHost || isConnecting)
                        }
                    }
                }

                if !connectedAccounts.isEmpty {
                    Section {
                        ForEach(connectedAccounts, id: \.id) { account in
                            connectedAccountRow(account)
                        }
                    } header: {
                        Text(String(
                            localized: "cloudStorageConnectedAccounts",
                            defaultValue: "Connected Accounts"
                        ))
                    } footer: {
                        Text(String(
                            localized: "cloudStorageConnectedAccountsDescription",
                            defaultValue: "Select an existing account to choose another linked folder."
                        ))
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isOperationInProgress)
        }
        .onDisappear {
            cancelOperation()
        }
        .task(id: isExcaliDash ? serverURL : "") {
            guard isExcaliDash else { return }
            excaliDashSignIn = nil
            // Debounce typing before probing the server.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, hasServerHost,
                  let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            let options = await ExcaliDashSignInOptions.probe(url)
            guard !Task.isCancelled else { return }
            excaliDashSignIn = options
        }
#if os(macOS)
        .frame(minWidth: 620, idealWidth: 700, minHeight: 600, idealHeight: 680)
#endif
    }

    private var header: some View {
        ZStack {
            Text(String(
                format: String(
                    localized: "cloudStorageConnectProviderFormat",
                    defaultValue: "Connect %@"
                ),
                providerName
            ))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 72)
                .frame(maxWidth: .infinity)

            HStack {
                Button {
                    dismissSheet()
                } label: {
                    Image(systemName: "xmark")
                }
                .modernButtonStyle(style: .glass, size: .large, shape: .circle)

                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 68)
    }

    private var isOperationInProgress: Bool {
        isConnecting || openingAccountID != nil
    }

    private var isExcaliDash: Bool {
        providerID == .excaliDash
    }

    private var hasServerHost: Bool {
        URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host != nil
    }

    /// ExcaliDash servers that enforce SSO have no use for a password.
    private var showsPasswordFields: Bool {
        !(isExcaliDash && excaliDashSignIn?.singleSignOnOnly == true)
    }

    private var singleSignOnTitle: String {
        if let provider = excaliDashSignIn?.providerName {
            return String(
                format: String(
                    localized: "cloudStorageSignInWithProviderFormat",
                    defaultValue: "Sign in with %@"
                ),
                provider
            )
        }
        return String(localized: "cloudStorageSignInWithSSO", defaultValue: "Sign in with SSO")
    }

    private var canConnect: Bool {
        if isExcaliDash {
            // Servers with sign-in disabled need no credentials.
            let hasHost = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host != nil
            let hasUsername = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasHost && hasUsername == !password.isEmpty
        }
        return URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    private var detectedServiceName: String? {
        guard let url = URL(
            string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ), url.host != nil else {
            return nil
        }
        return WebDAVServiceIdentity.displayName(for: url)
    }

    private func connectedAccountRow(_ account: CloudStorageAccount) -> some View {
        Button {
            open(account)
        } label: {
            HStack(spacing: 12) {
                CloudStorageProviderIcon(
                    providerID: account.providerID,
                    size: 28,
                    accountDisplayName: account.displayName
                )
                .frame(width: 32, height: 32)

                Text(account.displayName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 12)

                if openingAccountID == account.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ account: CloudStorageAccount) {
        guard !isOperationInProgress else { return }
        openingAccountID = account.id
        errorMessage = nil
        operationTask = Task { @MainActor in
            defer {
                openingAccountID = nil
                operationTask = nil
            }
            do {
                try await onSelectAccount(account)
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch CloudStorageError.authorizationCancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func connect(useSingleSignOn: Bool = false) {
        guard !isOperationInProgress else { return }
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL) else { return }

        isConnecting = true
        isUsingSingleSignOn = useSingleSignOn
        errorMessage = nil
        operationTask = Task { @MainActor in
            defer {
                isConnecting = false
                operationTask = nil
            }
            do {
                try await onConnect(
                    CloudStorageServerCredentials(
                        serverURL: url,
                        username: useSingleSignOn ? "" : username.trimmingCharacters(in: .whitespacesAndNewlines),
                        password: useSingleSignOn ? "" : password,
                        useSingleSignOn: useSingleSignOn
                    )
                )
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch CloudStorageError.authorizationCancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func dismissSheet() {
        cancelOperation()
        dismiss()
    }

    private func cancelOperation() {
        operationTask?.cancel()
        operationTask = nil
    }
}

/// What an ExcaliDash server offers for signing in, shown before connecting.
struct ExcaliDashSignInOptions: Sendable {
    let providerName: String?
    let singleSignOnOnly: Bool

    static func probe(_ url: URL) async -> ExcaliDashSignInOptions? {
        guard let endpoint = try? await ExcaliDashEndpointResolver.resolve(url),
              let status = try? await ExcaliDashAPIClient(endpoint: endpoint, login: nil).authStatus() else {
            return nil
        }
        let provider = status.oidcEnabled == true
            ? status.oidcProvider.flatMap { $0.isEmpty || $0 == "OIDC" ? nil : $0 }
            : nil
        return .init(providerName: provider, singleSignOnOnly: status.oidcEnforced == true)
    }
}
