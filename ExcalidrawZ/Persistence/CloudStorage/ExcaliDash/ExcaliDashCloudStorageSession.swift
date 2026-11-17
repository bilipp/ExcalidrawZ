//
//  ExcaliDashCloudStorageSession.swift
//  ExcalidrawZ
//
//  Presents an ExcaliDash server as a folder tree:
//
//    <server>                     root (unorganized drawings live here)
//    ├── <collection>/            one folder per collection (flat)
//    ├── Shared with me/          drawings other users shared directly
//    └── <drawing>.excalidraw
//
//  Drawings are materialized as standard `.excalidraw` documents so the
//  document store, editor, checkpoints and conflict handling work unchanged.
//  The drawing's server `version` is the item revision, and saves send it
//  back so a concurrent edit on the web answers 409 instead of being
//  overwritten.
//

import Foundation

actor ExcaliDashCloudStorageSession: CloudStorageSession {
    nonisolated let providerID = CloudStorageProviderID.excaliDash
    nonisolated let account: CloudStorageAccount
    nonisolated let capabilities: CloudStorageProviderCapabilities = .readWrite

    private let credential: ExcaliDashCredential
    private let client: ExcaliDashAPIClient
    private static let pageSize = 200
    private static let sceneReuseInterval: TimeInterval = 30
    private static let assetCacheLimit = 64 * 1024 * 1024

    /// Parent folder each drawing was last seen in; the API only reports a
    /// collection id to the drawing's owner.
    private var drawingParents: [String: ExcaliDashItemID] = [:]
    private var drawingSummaries: [String: ExcaliDashDrawingSummary] = [:]
    private var collections: [String: ExcaliDashCollection] = [:]
    /// File ids already stored server-side per drawing. Saves only upload
    /// images that are new, because the server merges `files` additively.
    private var serverFileIDs: [String: Set<String>] = [:]
    /// Scene fetched by a freshness check, reused by the download that
    /// usually follows immediately.
    private var recentScenes: [String: (data: Data, fetchedAt: Date)] = [:]
    /// Immutable image bytes keyed by server reference, as data URLs.
    private var assetCache: [String: String] = [:]
    private var assetCacheBytes = 0

    init(
        account: CloudStorageAccount,
        credential: ExcaliDashCredential,
        client: ExcaliDashAPIClient
    ) {
        self.account = account
        self.credential = credential
        self.client = client
    }

    // MARK: - Browsing

    func rootItem() async throws -> CloudStorageItem {
        folderItem(
            id: .root,
            parent: nil,
            name: credential.siteURL.host() ?? "ExcaliDash",
            capabilities: [.createChildren]
        )
    }

    func item(for id: CloudStorageItemID) async throws -> CloudStorageItem {
        switch try ExcaliDashItemID(id) {
            case .root:
                return try await rootItem()
            case .sharedWithMe:
                return sharedFolderItem()
            case .collection(let collectionID):
                try await reloadCollections()
                guard let collection = collections[collectionID] else {
                    throw CloudStorageError.itemNotFound(id)
                }
                return collectionItem(collection)
            case .drawing(let drawingID):
                if let summary = try await lightweightSummary(for: drawingID) {
                    return drawingItem(summary)
                }
                let data = try await fetchScene(drawingID)
                recentScenes[drawingID] = (data, Date())
                return try drawingItem(fromScene: data, id: id)
        }
    }

    func remoteURL(for item: CloudStorageItem) async throws -> URL {
        switch try ExcaliDashItemID(item.id) {
            case .drawing(let drawingID):
                return credential.siteURL.appending(path: "editor/\(drawingID)")
            case .collection, .sharedWithMe:
                return credential.siteURL.appending(path: "collections")
            case .root:
                return credential.siteURL
        }
    }

    func listChildren(
        of folderID: CloudStorageItemID,
        pageToken: String?
    ) async throws -> CloudStorageItemPage {
        let offset = pageToken.flatMap { Int($0.dropFirst(2)) } ?? 0
        let folder = try ExcaliDashItemID(folderID)
        var items: [CloudStorageItem] = []

        let drawingsPath: String
        var query: [URLQueryItem] = []
        switch folder {
            case .root:
                drawingsPath = "drawings"
                query.append(URLQueryItem(name: "collectionId", value: "null"))
                if offset == 0 {
                    try await reloadCollections()
                    items += collections.values
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        .map(collectionItem)
                    if try await hasSharedDrawings() {
                        items.append(sharedFolderItem())
                    }
                }
            case .collection(let collectionID):
                drawingsPath = "drawings"
                query.append(URLQueryItem(name: "collectionId", value: collectionID))
                if collections[collectionID] == nil {
                    try? await reloadCollections()
                }
            case .sharedWithMe:
                drawingsPath = "drawings/shared"
            case .drawing:
                throw CloudStorageError.invalidProviderResponse("A drawing has no children.")
        }

        query += [
            URLQueryItem(name: "limit", value: String(Self.pageSize)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "sortField", value: "name"),
        ]
        let data = try await client.get(drawingsPath, query: query, operation: .browse)
        let page = try ExcaliDashAPIClient.decode(ExcaliDashDrawingPage.self, from: data)
        for summary in page.drawings {
            remember(summary, parent: folder)
            items.append(drawingItem(summary))
        }

        let nextOffset = offset + page.drawings.count
        let hasMore = page.drawings.count == Self.pageSize
            && nextOffset < (page.totalCount ?? Int.max)
        return CloudStorageItemPage(
            items: items,
            nextPageToken: hasMore ? "o:\(nextOffset)" : nil
        )
    }

    // MARK: - Content

    func downloadFile(
        _ fileID: CloudStorageItemID,
        to localURL: URL
    ) async throws -> CloudStorageItem {
        guard case .drawing(let drawingID) = try ExcaliDashItemID(fileID) else {
            throw CloudStorageError.itemNotFound(fileID)
        }
        let data: Data
        if let recent = recentScenes.removeValue(forKey: drawingID),
           Date().timeIntervalSince(recent.fetchedAt) < Self.sceneReuseInterval {
            data = recent.data
        } else {
            data = try await fetchScene(drawingID)
        }

        guard let scene = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudStorageError.invalidProviderResponse("ExcaliDash returned an invalid drawing.")
        }
        let files = scene["files"] as? [String: Any] ?? [:]
        serverFileIDs[drawingID] = Set(files.keys)
        let document = try ExcaliDashScene.makeDocument(
            elements: scene["elements"] ?? [],
            appState: scene["appState"] ?? [:],
            files: try await inlineFiles(files),
            source: credential.siteURL
        )
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try document.write(to: localURL, options: .atomic)
        return try drawingItem(fromScene: data, id: fileID)
    }

    func createFile(
        named name: String,
        in parentID: CloudStorageItemID,
        contentsAt localURL: URL,
        condition: CloudStorageWriteCondition
    ) async throws -> CloudStorageItem {
        let parent = try ExcaliDashItemID(parentID)
        let collectionID: Any
        switch parent {
            case .root: collectionID = NSNull()
            case .collection(let id): collectionID = id
            case .sharedWithMe, .drawing: throw CloudStorageError.permissionDenied(.createFile)
        }
        let scene = try ExcaliDashScene.parseDocument(at: localURL)
        let data = try await client.send("POST", "drawings", json: [
            "name": ExcaliDashItemID.drawingName(fromFileName: name),
            "collectionId": collectionID,
            "elements": scene.elements,
            "appState": scene.appState,
            "files": scene.files,
            "preview": NSNull(),
        ] as [String: Any], operation: .createFile)
        return try storeSaveResponse(data, parent: parent)
    }

    func updateFile(
        _ fileID: CloudStorageItemID,
        contentsAt localURL: URL,
        condition: CloudStorageWriteCondition
    ) async throws -> CloudStorageItem {
        guard case .drawing(let drawingID) = try ExcaliDashItemID(fileID) else {
            throw CloudStorageError.itemNotFound(fileID)
        }
        let scene = try ExcaliDashScene.parseDocument(at: localURL)

        let knownFileIDs: Set<String>
        if let cached = serverFileIDs[drawingID] {
            knownFileIDs = cached
        } else {
            let current = try await fetchScene(drawingID)
            let object = try JSONSerialization.jsonObject(with: current) as? [String: Any]
            knownFileIDs = Set((object?["files"] as? [String: Any] ?? [:]).keys)
        }
        let newFiles = scene.files.filter { !knownFileIDs.contains($0.key) }

        var body: [String: Any] = [
            "elements": scene.elements,
            "appState": scene.appState,
            // Clear the stale thumbnail; the dashboard regenerates it.
            "preview": NSNull(),
        ]
        if !newFiles.isEmpty {
            body["files"] = newFiles
        }
        switch condition {
            case .ifUnmodified(let revision):
                if let version = Int(revision) { body["version"] = version }
            case .ifAbsent:
                throw CloudStorageError.conflict
            case .unconditional:
                break
        }

        recentScenes.removeValue(forKey: drawingID)
        let data = try await client.send("PUT", "drawings/\(drawingID)", json: body, operation: .updateFile)
        return try storeSaveResponse(data, parent: drawingParents[drawingID])
    }

    // MARK: - Organization

    func createFolder(
        named name: String,
        in parentID: CloudStorageItemID
    ) async throws -> CloudStorageItem {
        guard case .root = try ExcaliDashItemID(parentID) else {
            throw CloudStorageError.invalidProviderResponse(
                "ExcaliDash collections cannot be nested. Create the collection at the top level instead."
            )
        }
        let data = try await client.send(
            "POST", "collections",
            json: ["name": String(name.prefix(100))],
            operation: .createFolder
        )
        let collection = try ExcaliDashAPIClient.decode(ExcaliDashCollection.self, from: data)
        collections[collection.id] = collection
        return collectionItem(collection)
    }

    func moveItem(
        _ itemID: CloudStorageItemID,
        to parentID: CloudStorageItemID?,
        newName: String?
    ) async throws -> CloudStorageItem {
        switch try ExcaliDashItemID(itemID) {
            case .drawing(let drawingID):
                var body: [String: Any] = [:]
                var parent = drawingParents[drawingID]
                if let newName {
                    body["name"] = ExcaliDashItemID.drawingName(fromFileName: newName)
                }
                if let parentID {
                    let target = try ExcaliDashItemID(parentID)
                    switch target {
                        case .root: body["collectionId"] = NSNull()
                        case .collection(let id): body["collectionId"] = id
                        case .sharedWithMe, .drawing: throw CloudStorageError.permissionDenied(.moveItem)
                    }
                    parent = target
                }
                guard !body.isEmpty else { return try await item(for: itemID) }
                let data = try await client.send(
                    "PUT", "drawings/\(drawingID)",
                    json: body,
                    operation: .moveItem
                )
                return try storeSaveResponse(data, parent: parent)

            case .collection(let collectionID):
                if let parentID, try ExcaliDashItemID(parentID) != .root {
                    throw CloudStorageError.invalidProviderResponse(
                        "ExcaliDash collections cannot be nested."
                    )
                }
                guard let newName else { return try await item(for: itemID) }
                _ = try await client.send(
                    "PUT", "collections/\(collectionID)",
                    json: ["name": String(newName.prefix(100))],
                    operation: .moveItem
                )
                try await reloadCollections()
                return try await item(for: itemID)

            case .root, .sharedWithMe:
                throw CloudStorageError.permissionDenied(.moveItem)
        }
    }

    func deleteItem(
        _ itemID: CloudStorageItemID,
        condition: CloudStorageWriteCondition
    ) async throws {
        switch try ExcaliDashItemID(itemID) {
            case .drawing(let drawingID):
                // Soft delete: the drawing stays restorable from the
                // ExcaliDash trash, matching the web dashboard's behavior.
                _ = try await client.send(
                    "PUT", "drawings/\(drawingID)",
                    json: ["collectionId": "trash"],
                    operation: .deleteItem
                )
                forget(drawingID)
            case .collection(let collectionID):
                // The server moves the collection's drawings to the root.
                try await client.delete("collections/\(collectionID)", operation: .deleteItem)
                collections.removeValue(forKey: collectionID)
                drawingParents = drawingParents.mapValues {
                    $0 == .collection(collectionID) ? .root : $0
                }
            case .root, .sharedWithMe:
                throw CloudStorageError.permissionDenied(.deleteItem)
        }
    }

    // MARK: - Requests

    private func fetchScene(_ drawingID: String) async throws -> Data {
        do {
            return try await client.get("drawings/\(drawingID)", operation: .download)
        } catch CloudStorageError.itemNotFound {
            forget(drawingID)
            throw CloudStorageError.itemNotFound(ExcaliDashItemID.drawing(drawingID).cloudID)
        }
    }

    /// Revision checks run every few seconds for the open drawing. A name
    /// search over its folder returns version and timestamps without
    /// transferring the scene; a full fetch is the fallback after a rename.
    private func lightweightSummary(for drawingID: String) async throws -> ExcaliDashDrawingSummary? {
        guard let known = drawingSummaries[drawingID],
              let parent = drawingParents[drawingID] else { return nil }
        var query = [
            URLQueryItem(name: "search", value: known.name),
            URLQueryItem(name: "limit", value: "50"),
        ]
        let path: String
        switch parent {
            case .root:
                path = "drawings"
                query.append(URLQueryItem(name: "collectionId", value: "null"))
            case .collection(let id):
                path = "drawings"
                query.append(URLQueryItem(name: "collectionId", value: id))
            case .sharedWithMe:
                path = "drawings/shared"
            case .drawing:
                return nil
        }
        guard let data = try? await client.get(path, query: query, operation: .browse),
              let page = try? ExcaliDashAPIClient.decode(ExcaliDashDrawingPage.self, from: data),
              let summary = page.drawings.first(where: { $0.id == drawingID }) else {
            return nil
        }
        remember(summary, parent: parent)
        return summary
    }

    private func reloadCollections() async throws {
        let data = try await client.get("collections", operation: .browse)
        let list = try ExcaliDashAPIClient.decode([ExcaliDashCollection].self, from: data)
        collections = Dictionary(
            list.filter { !$0.isTrash }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func hasSharedDrawings() async throws -> Bool {
        guard credential.requiresAuthentication else { return false }
        guard let data = try? await client.get(
            "drawings/shared",
            query: [URLQueryItem(name: "limit", value: "1")],
            operation: .browse
        ), let page = try? ExcaliDashAPIClient.decode(ExcaliDashDrawingPage.self, from: data) else {
            return false
        }
        return !page.drawings.isEmpty
    }

    /// Server scenes reference images as `/api/files/...` (or S3 URLs); the
    /// editor needs inline data URLs.
    private func inlineFiles(_ files: [String: Any]) async throws -> [String: Any] {
        var result: [String: Any] = [:]
        for (fileID, value) in files {
            guard var file = value as? [String: Any] else { continue }
            if let reference = file["dataURL"] as? String, !reference.hasPrefix("data:") {
                do {
                    file["dataURL"] = try await dataURL(for: reference, mimeType: file["mimeType"] as? String)
                } catch CloudStorageError.itemNotFound {
                    // A missing blob must not make the whole drawing unreadable;
                    // Excalidraw shows its placeholder for that image.
                    continue
                }
            }
            result[fileID] = file
        }
        return result
    }

    private func dataURL(for reference: String, mimeType: String?) async throws -> String {
        if let cached = assetCache[reference] { return cached }
        let (bytes, responseMimeType) = try await client.fetchAsset(reference)
        let type = mimeType ?? responseMimeType ?? "application/octet-stream"
        let dataURL = "data:\(type);base64,\(bytes.base64EncodedString())"
        if assetCacheBytes + dataURL.utf8.count > Self.assetCacheLimit {
            assetCache.removeAll()
            assetCacheBytes = 0
        }
        assetCache[reference] = dataURL
        assetCacheBytes += dataURL.utf8.count
        return dataURL
    }

    // MARK: - Mapping

    private func storeSaveResponse(_ data: Data, parent: ExcaliDashItemID?) throws -> CloudStorageItem {
        let summary = try ExcaliDashAPIClient.decode(ExcaliDashDrawingSummary.self, from: data)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = object["files"] as? [String: Any] {
            serverFileIDs[summary.id] = Set(files.keys)
        }
        remember(summary, parent: resolvedParent(for: summary, fallback: parent))
        return drawingItem(summary)
    }

    private func drawingItem(fromScene data: Data, id: CloudStorageItemID) throws -> CloudStorageItem {
        let summary = try ExcaliDashAPIClient.decode(ExcaliDashDrawingSummary.self, from: data)
        if summary.collectionId == "trash" || summary.collectionId?.hasPrefix("trash:") == true {
            forget(summary.id)
            throw CloudStorageError.itemNotFound(id)
        }
        remember(summary, parent: resolvedParent(for: summary, fallback: drawingParents[summary.id]))
        return drawingItem(summary)
    }

    private func resolvedParent(
        for summary: ExcaliDashDrawingSummary,
        fallback: ExcaliDashItemID?
    ) -> ExcaliDashItemID {
        if let collectionID = summary.collectionId {
            return .collection(collectionID)
        }
        // The API reports `collectionId: null` both for unorganized drawings
        // and for drawings the caller does not own.
        if isOwnedByMe(summary) { return .root }
        return fallback ?? .sharedWithMe
    }

    private func remember(_ summary: ExcaliDashDrawingSummary, parent: ExcaliDashItemID) {
        drawingSummaries[summary.id] = summary
        drawingParents[summary.id] = parent
    }

    private func forget(_ drawingID: String) {
        drawingSummaries.removeValue(forKey: drawingID)
        drawingParents.removeValue(forKey: drawingID)
        serverFileIDs.removeValue(forKey: drawingID)
        recentScenes.removeValue(forKey: drawingID)
    }

    private func isOwnedByMe(_ summary: ExcaliDashDrawingSummary) -> Bool {
        if let accessLevel = summary.accessLevel { return accessLevel == "owner" }
        // "sso": signed in with a key whose owner the server would not reveal.
        guard let userID = summary.userId, credential.userID != "sso" else { return true }
        return userID == credential.userID
    }

    private func drawingItem(_ summary: ExcaliDashDrawingSummary) -> CloudStorageItem {
        let parent = drawingParents[summary.id] ?? .root
        return CloudStorageItem(
            id: ExcaliDashItemID.drawing(summary.id).cloudID,
            parentID: parent.cloudID,
            name: ExcaliDashItemID.fileName(forDrawingName: summary.name),
            kind: .file,
            contentType: "application/vnd.excalidraw+json",
            size: nil,
            createdAt: summary.createdAt,
            modifiedAt: summary.updatedAt,
            remoteURL: credential.siteURL.appending(path: "editor/\(summary.id)"),
            revision: String(summary.version),
            capabilities: drawingCapabilities(summary, parent: parent)
        )
    }

    private func drawingCapabilities(
        _ summary: ExcaliDashDrawingSummary,
        parent: ExcaliDashItemID
    ) -> CloudStorageItemCapabilities {
        let editable: CloudStorageItemCapabilities = [.download, .updateContent, .rename]
        switch summary.accessLevel {
            case "owner": return .writableFile
            case "edit": return editable
            case "view": return [.download]
            default: break
        }
        if isOwnedByMe(summary) { return .writableFile }
        if case .collection(let id) = parent, let role = collections[id]?.sharedRole {
            return role == "view" ? [.download] : editable
        }
        return parent == .sharedWithMe ? [.download] : editable
    }

    private func collectionItem(_ collection: ExcaliDashCollection) -> CloudStorageItem {
        let capabilities: CloudStorageItemCapabilities
        if collection.isOwner ?? true {
            capabilities = [.createChildren, .rename, .delete]
        } else if collection.sharedRole == "edit" {
            capabilities = [.createChildren]
        } else {
            capabilities = []
        }
        return CloudStorageItem(
            id: ExcaliDashItemID.collection(collection.id).cloudID,
            parentID: ExcaliDashItemID.root.cloudID,
            name: collection.name,
            kind: .folder,
            contentType: nil,
            size: nil,
            createdAt: collection.createdAt,
            modifiedAt: collection.updatedAt,
            remoteURL: credential.siteURL.appending(path: "collections"),
            revision: nil,
            capabilities: capabilities
        )
    }

    private func sharedFolderItem() -> CloudStorageItem {
        folderItem(
            id: .sharedWithMe,
            parent: .root,
            name: String(localized: "excaliDashSharedWithMe", defaultValue: "Shared with me"),
            capabilities: []
        )
    }

    private func folderItem(
        id: ExcaliDashItemID,
        parent: ExcaliDashItemID?,
        name: String,
        capabilities: CloudStorageItemCapabilities
    ) -> CloudStorageItem {
        CloudStorageItem(
            id: id.cloudID,
            parentID: parent?.cloudID,
            name: name,
            kind: .folder,
            contentType: nil,
            size: nil,
            createdAt: nil,
            modifiedAt: nil,
            remoteURL: credential.siteURL,
            revision: nil,
            capabilities: capabilities
        )
    }
}
