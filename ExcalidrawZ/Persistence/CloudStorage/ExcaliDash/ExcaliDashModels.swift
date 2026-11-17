//
//  ExcaliDashModels.swift
//  ExcalidrawZ
//
//  Wire models for the ExcaliDash REST API and the mapping between its
//  drawings/collections and provider-neutral cloud storage items.
//

import Foundation

enum ExcaliDashJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let milliseconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: milliseconds / 1000)
            }
            let string = try container.decode(String.self)
            if let date = fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 date \(string)"
            )
        }
        return decoder
    }()

    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainFormatter = ISO8601DateFormatter()
}

struct ExcaliDashErrorPayload: Decodable {
    let error: String?
    let message: String?
    let code: String?
}

struct ExcaliDashCSRFToken: Decodable {
    let token: String
}

struct ExcaliDashAuthStatus: Decodable, Sendable {
    let enabled: Bool?
    let authEnabled: Bool?
    let authenticated: Bool?
    let oidcEnforced: Bool?
    let authOnboardingRequired: Bool?
    let bootstrapRequired: Bool?

    /// Whether the server requires signing in at all.
    var requiresLogin: Bool {
        authEnabled ?? enabled ?? true
    }
}

struct ExcaliDashUser: Codable, Sendable {
    let id: String
    let email: String?
    let name: String?
    let username: String?
    let mustResetPassword: Bool?

    /// Every request runs as this user while authentication is disabled.
    static let anonymous = ExcaliDashUser(
        id: "bootstrap-admin",
        email: nil,
        name: nil,
        username: nil,
        mustResetPassword: false
    )
}

struct ExcaliDashLoginResponse: Decodable {
    let user: ExcaliDashUser
}

struct ExcaliDashCollection: Decodable, Sendable {
    let id: String
    let name: String
    let createdAt: Date?
    let updatedAt: Date?
    let isOwner: Bool?
    let sharedRole: String?

    var isTrash: Bool { id == "trash" || id.hasPrefix("trash:") }
}

/// A drawing as returned by list (metadata only) or by `GET /drawings/:id`
/// (scene included, decoded separately as raw JSON).
struct ExcaliDashDrawingSummary: Decodable, Sendable {
    let id: String
    let name: String
    let collectionId: String?
    let version: Int
    let createdAt: Date?
    let updatedAt: Date?
    let userId: String?
    let accessLevel: String?
}

struct ExcaliDashDrawingPage: Decodable {
    let drawings: [ExcaliDashDrawingSummary]
    let totalCount: Int?
    let limit: Int?
    let offset: Int?
}

/// Opaque identifiers exposed to the document store. ExcaliDash collections
/// are flat, so the tree is: root → collections / unorganized drawings /
/// "Shared with me" → drawings.
enum ExcaliDashItemID: Hashable, Sendable {
    case root
    case sharedWithMe
    case collection(String)
    case drawing(String)

    static let fileExtension = ".excalidraw"

    init(_ id: CloudStorageItemID) throws {
        let raw = id.rawValue
        switch raw {
            case "root": self = .root
            case "shared": self = .sharedWithMe
            case _ where raw.hasPrefix("c:"): self = .collection(String(raw.dropFirst(2)))
            case _ where raw.hasPrefix("d:"): self = .drawing(String(raw.dropFirst(2)))
            default: throw CloudStorageError.itemNotFound(id)
        }
    }

    var cloudID: CloudStorageItemID {
        switch self {
            case .root: CloudStorageItemID(rawValue: "root")
            case .sharedWithMe: CloudStorageItemID(rawValue: "shared")
            case .collection(let id): CloudStorageItemID(rawValue: "c:\(id)")
            case .drawing(let id): CloudStorageItemID(rawValue: "d:\(id)")
        }
    }

    /// Converts a document store file name back into an ExcaliDash name.
    static func drawingName(fromFileName fileName: String) -> String {
        var name = fileName
        for suffix in [".excalidraw.png", ".excalidraw.svg", fileExtension] where
            name.lowercased().hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled Drawing" : String(name.prefix(255))
    }

    static func fileName(forDrawingName name: String) -> String {
        name.replacingOccurrences(of: "/", with: "∕") + fileExtension
    }
}

/// Converts between ExcaliDash scenes and `.excalidraw` documents.
enum ExcaliDashScene {
    struct Parsed {
        var elements: [Any]
        var appState: [String: Any]
        var files: [String: [String: Any]]
    }

    static func parseDocument(at url: URL) throws -> Parsed {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudStorageError.invalidProviderResponse("The drawing is not valid Excalidraw JSON.")
        }
        return Parsed(
            elements: object["elements"] as? [Any] ?? [],
            appState: sanitizedAppState(object["appState"] as? [String: Any] ?? [:]),
            files: object["files"] as? [String: [String: Any]] ?? [:]
        )
    }

    static func makeDocument(
        elements: Any,
        appState: Any,
        files: [String: Any],
        source: URL
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "excalidraw",
            "version": 2,
            "source": source.absoluteString,
            "elements": elements,
            "appState": appState,
            "files": files,
        ] as [String: Any])
    }

    /// ExcaliDash validates appState strictly (ranges, enums). Values the
    /// editor persists as `null`, and transient collaboration state, are
    /// dropped so a stock Excalidraw document always passes.
    static func sanitizedAppState(_ appState: [String: Any]) -> [String: Any] {
        var result = appState.filter { !($0.value is NSNull) }
        result.removeValue(forKey: "collaborators")
        if let gridSize = result["gridSize"] as? Double, !(0...1000).contains(gridSize) {
            result.removeValue(forKey: "gridSize")
        }
        if let gridStep = result["gridStep"] as? Double, !(1...1000).contains(gridStep) {
            result.removeValue(forKey: "gridStep")
        }
        return result
    }
}
