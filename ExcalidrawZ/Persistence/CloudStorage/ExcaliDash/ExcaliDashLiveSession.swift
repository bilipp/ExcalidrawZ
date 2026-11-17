//
//  ExcaliDashLiveSession.swift
//  ExcalidrawZ
//
//  Live collaboration for an ExcaliDash drawing open in the editor. Speaks
//  the same realtime protocol as the ExcaliDash web editor, so ExcalidrawZ and
//  browser users see each other's edits and cursors as they happen:
//
//  - `element-update {drawingId, elements, files, elementOrder, userId}`:
//    changed elements only, at most every 100 ms.
//  - `cursor-move {drawingId, pointer, button, username, userId, color}`.
//  - `user-activity {drawingId, isActive}` and `presence-update [users]`.
//
//  The bundled editor exposes no change deltas or pointer events to Swift, so
//  a small script installed into the page diffs elements by version, reports
//  pointer moves in scene coordinates, and merges incoming elements with
//  Excalidraw's own rule (higher version wins, ties to the lower nonce).
//  Saving stays with the normal document pipeline: concurrent saves merge on
//  the server side of `ExcaliDashCloudStorageSession.updateFile`.
//

import Foundation
import Logging
import WebKit

@MainActor
final class ExcaliDashLiveSession: NSObject {
    private static let handlerName = "excalidashLive"
    private static let palette = [
        "#e03131", "#2f9e44", "#1971c2", "#f08c00",
        "#9c36b5", "#0c8599", "#e8590c", "#6741d9",
    ]

    let drawingID: String
    private let client: ExcaliDashAPIClient
    private let socket: ExcaliDashSocket
    private weak var webView: WKWebView?
    private let logger = Logger(label: "ExcaliDashLiveSession")

    private var me: [String: Any]
    private var cursors: [String: [String: Any]] = [:]
    private var presence: [[String: Any]] = []
    private var assetCache: [String: String] = [:]
    private var isStopped = false
    private var isJoined = false

    /// Joined the drawing's room and receiving peers' edits. False on servers
    /// that refuse the socket, so the regular polling keeps working there.
    var isReceivingLiveUpdates: Bool { isJoined && !isStopped }

    init(
        drawingID: String,
        credential: ExcaliDashCredential,
        client: ExcaliDashAPIClient,
        webView: WKWebView
    ) {
        self.drawingID = drawingID
        self.client = client
        self.webView = webView
        self.socket = ExcaliDashSocket(siteURL: credential.siteURL) { [client] in
            await client.realtimeToken()
        }
        let name = credential.userName ?? credential.email ?? "ExcalidrawZ"
        let seed = credential.userID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        self.me = [
            "id": credential.userID,
            "name": name,
            "color": Self.palette[seed % Self.palette.count],
        ]
        super.init()
    }

    // MARK: - Lifecycle

    func start() async {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.handlerName)
        controller.add(WeakScriptMessageHandler(self), name: Self.handlerName)

        // The editor may still be loading the drawing; wait for its API.
        var installed = false
        for _ in 0..<60 where !isStopped {
            if (try? await webView.callAsyncJavaScript(
                Self.bridgeScript + "\nreturn window.__exdLive.install();",
                arguments: [:],
                contentWorld: .page
            )) as? Bool == true {
                installed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard installed, !isStopped else {
            logger.warning("Live collaboration unavailable: the editor did not become ready")
            return
        }

        await socket.setEventHandler { [weak self] event in
            await self?.handle(event)
        }
        await socket.connect()
        logger.info("Live collaboration started for drawing \(drawingID)")
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        await socket.disconnect()
        if let webView {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
            _ = try? await webView.callAsyncJavaScript(
                "window.__exdLive && window.__exdLive.uninstall();",
                arguments: [:],
                contentWorld: .page
            )
        }
        logger.info("Live collaboration stopped for drawing \(drawingID)")
    }

    // MARK: - Socket → editor

    private func handle(_ event: ExcaliDashSocket.Event) async {
        guard !isStopped else { return }
        switch event {
            case .connected:
                await join()
            case .disconnected(let reason):
                isJoined = false
                logger.info("Live collaboration disconnected: \(reason)")
                cursors.removeAll()
                presence.removeAll()
                await pushCollaborators()
            case .message(let name, let payload):
                await handleMessage(name, payload as? [String: Any], raw: payload)
        }
    }

    private func join() async {
        do {
            let ack = try await socket.emitWithAck(
                "join-room",
                ["drawingId": drawingID, "user": me]
            ) as? [String: Any]
            if let user = ack?["user"] as? [String: Any] {
                me.merge(user) { _, server in server }
            }
            isJoined = true
            await catchUp()
        } catch {
            logger.warning("Joining the live drawing failed: \(error.localizedDescription)")
        }
    }

    /// After (re)joining, pull the saved drawing so edits made while this
    /// client was offline appear; the merge keeps anything newer locally.
    private func catchUp() async {
        guard let data = try? await client.get("drawings/\(drawingID)", operation: .download),
              let scene = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        await apply(
            elements: scene["elements"] as? [Any] ?? [],
            files: scene["files"] as? [String: Any] ?? [:],
            order: nil
        )
    }

    private func handleMessage(_ name: String, _ payload: [String: Any]?, raw: Any?) async {
        switch name {
            case "element-update":
                guard let payload, payload["drawingId"] as? String == drawingID else { return }
                await apply(
                    elements: payload["elements"] as? [Any] ?? [],
                    files: payload["files"] as? [String: Any] ?? [:],
                    order: payload["persisted"] as? Bool == true ? nil : payload["elementOrder"] as? [Any]
                )
            case "cursor-move":
                guard let payload, payload["drawingId"] as? String == drawingID,
                      let userID = payload["userId"] as? String, userID != me["id"] as? String,
                      let pointer = payload["pointer"] as? [String: Any] else { return }
                let color = payload["color"] as? String ?? "#4f46e5"
                cursors[userID] = [
                    "id": userID,
                    "username": payload["username"] as? String ?? "User",
                    "pointer": pointer,
                    "button": payload["button"] as? String ?? "up",
                    "color": color,
                ]
                await pushCollaborators()
            case "presence-update":
                presence = (raw as? [[String: Any]] ?? []).filter { $0["id"] as? String != me["id"] as? String }
                let present = Set(presence.compactMap { $0["id"] as? String })
                cursors = cursors.filter { present.contains($0.key) }
                await pushCollaborators()
            case "error":
                if payload?["message"] as? String == "You do not have access to this drawing" {
                    isJoined = false
                }
                logger.warning("ExcaliDash live error: \(payload?["message"] as? String ?? "unknown")")
            default:
                break
        }
    }

    private func apply(elements: [Any], files: [String: Any], order: [Any]?) async {
        guard let webView, !elements.isEmpty || !files.isEmpty || order != nil else { return }
        let resolvedFiles = await resolveFiles(files)
        _ = try? await webView.callAsyncJavaScript(
            "return window.__exdLive && window.__exdLive.apply(payload);",
            arguments: ["payload": [
                "elements": elements,
                "files": resolvedFiles,
                "elementOrder": order ?? NSNull(),
            ] as [String: Any]],
            contentWorld: .page
        )
    }

    /// Peers send server refs (`/api/files/...`) for uploaded images; the
    /// editor can only show inline data URLs, and the page cannot fetch the
    /// server with our credentials.
    private func resolveFiles(_ files: [String: Any]) async -> [String: Any] {
        guard !files.isEmpty, let webView else { return [:] }
        let known = Set((try? await webView.callAsyncJavaScript(
            "return window.__exdLive ? window.__exdLive.knownFileIds() : [];",
            arguments: [:],
            contentWorld: .page
        )) as? [String] ?? [])
        var result: [String: Any] = [:]
        for (id, value) in files where !known.contains(id) {
            guard var file = value as? [String: Any],
                  let reference = file["dataURL"] as? String, !reference.isEmpty else { continue }
            if !reference.hasPrefix("data:") {
                if let cached = assetCache[reference] {
                    file["dataURL"] = cached
                } else if let (bytes, mimeType) = try? await client.fetchAsset(reference) {
                    let type = file["mimeType"] as? String ?? mimeType ?? "application/octet-stream"
                    let dataURL = "data:\(type);base64,\(bytes.base64EncodedString())"
                    assetCache[reference] = dataURL
                    file["dataURL"] = dataURL
                } else {
                    continue
                }
            }
            result[id] = file
        }
        return result
    }

    private func pushCollaborators() async {
        guard let webView else { return }
        var entries: [[String: Any]] = []
        var seen = Set<String>()
        for (id, cursor) in cursors {
            seen.insert(id)
            entries.append(cursor)
        }
        // Present users without a cursor yet still show in the user list.
        for user in presence {
            guard let id = user["id"] as? String, !seen.contains(id) else { continue }
            seen.insert(id)
            entries.append([
                "id": id,
                "username": user["name"] as? String ?? "User",
                "color": user["color"] as? String ?? "#4f46e5",
                "isIdle": user["isActive"] as? Bool == false,
            ])
        }
        _ = try? await webView.callAsyncJavaScript(
            "window.__exdLive && window.__exdLive.setCollaborators(list);",
            arguments: ["list": entries],
            contentWorld: .page
        )
    }

    // MARK: - Editor → socket

    fileprivate func receive(_ body: Any) {
        guard !isStopped, let message = body as? [String: Any], let type = message["type"] as? String else { return }
        let socket = self.socket
        let drawingID = self.drawingID
        let me = self.me
        let isJoined = self.isJoined
        Task {
            guard isJoined else { return }
            switch type {
                case "elements":
                    var payload: [String: Any] = [
                        "drawingId": drawingID,
                        "elements": message["elements"] ?? [],
                        "userId": me["id"] ?? "",
                    ]
                    if let files = message["files"] as? [String: Any], !files.isEmpty {
                        payload["files"] = files
                    }
                    if let order = message["elementOrder"] as? [Any] {
                        payload["elementOrder"] = order
                    }
                    await socket.emit("element-update", payload)
                case "cursor":
                    await socket.emit("cursor-move", [
                        "drawingId": drawingID,
                        "pointer": message["pointer"] ?? [:],
                        "button": message["button"] ?? "up",
                        "username": me["name"] ?? "",
                        "userId": me["id"] ?? "",
                        "color": me["color"] ?? "",
                    ])
                case "activity":
                    await socket.emit("user-activity", [
                        "drawingId": drawingID,
                        "isActive": message["isActive"] as? Bool ?? true,
                    ])
                default:
                    break
            }
        }
    }

    // MARK: - Page script

    private static let bridgeScript = #"""
    if (!window.__exdLive) {
      window.__exdLive = (() => {
        const post = (message) => {
          try { window.webkit.messageHandlers.excalidashLive.postMessage(message); } catch (_) {}
        };
        const api = () => window.excalidrawZHelper && window.excalidrawZHelper._api;
        const key = (el) => `${el.version}:${el.versionNonce}`;
        let synced = new Map();
        let knownFiles = new Set();
        let lastOrder = "";
        let unsubscribe = null;
        let flushTimer = null;
        let lastFlushAt = 0;
        let lastCursorAt = 0;
        let button = "up";
        let applying = false;
        const listeners = [];

        const seed = () => {
          const editor = api();
          const elements = editor.getSceneElementsIncludingDeleted();
          synced = new Map(elements.map((el) => [el.id, key(el)]));
          lastOrder = elements.map((el) => el.id).join(",");
          knownFiles = new Set(Object.keys(editor.getFiles() || {}));
        };

        const flush = () => {
          flushTimer = null;
          lastFlushAt = Date.now();
          const editor = api();
          if (!editor) return;
          const elements = editor.getSceneElementsIncludingDeleted();
          const changes = [];
          for (const el of elements) {
            const k = key(el);
            if (synced.get(el.id) !== k) {
              synced.set(el.id, k);
              changes.push(el);
            }
          }
          const ids = elements.map((el) => el.id);
          const order = ids.join(",");
          const orderChanged = order !== lastOrder;
          lastOrder = order;
          const files = editor.getFiles() || {};
          const newFiles = {};
          for (const id of Object.keys(files)) {
            const file = files[id];
            if (!knownFiles.has(id) && file && typeof file.dataURL === "string" && file.dataURL.length > 0) {
              knownFiles.add(id);
              newFiles[id] = file;
            }
          }
          if (changes.length || orderChanged || Object.keys(newFiles).length) {
            post({
              type: "elements",
              elements: JSON.parse(JSON.stringify(changes)),
              files: JSON.parse(JSON.stringify(newFiles)),
              elementOrder: orderChanged ? ids : null,
            });
          }
        };

        const schedule = () => {
          if (applying || flushTimer) return;
          const wait = Math.max(0, 100 - (Date.now() - lastFlushAt));
          flushTimer = setTimeout(flush, wait);
        };

        const sceneCoords = (event) => {
          const state = api().getAppState();
          const zoom = (state.zoom && state.zoom.value) || 1;
          return {
            x: (event.clientX - (state.offsetLeft || 0)) / zoom - state.scrollX,
            y: (event.clientY - (state.offsetTop || 0)) / zoom - state.scrollY,
          };
        };

        const sendCursor = (event, force) => {
          const now = Date.now();
          if (!force && now - lastCursorAt < 50) return;
          lastCursorAt = now;
          const tool = (api().getAppState().activeTool || {}).type === "laser" ? "laser" : "pointer";
          post({ type: "cursor", pointer: { ...sceneCoords(event), tool }, button });
        };

        const listen = (target, name, handler) => {
          target.addEventListener(name, handler, true);
          listeners.push(() => target.removeEventListener(name, handler, true));
        };

        return {
          install() {
            const editor = api();
            if (!editor || typeof editor.onChange !== "function") return false;
            if (unsubscribe) return true;
            seed();
            unsubscribe = editor.onChange(() => schedule());
            listen(document, "pointermove", (e) => sendCursor(e, false));
            listen(document, "pointerdown", (e) => { button = "down"; sendCursor(e, true); });
            listen(document, "pointerup", (e) => { button = "up"; sendCursor(e, true); });
            listen(window, "focus", () => post({ type: "activity", isActive: true }));
            listen(window, "blur", () => post({ type: "activity", isActive: false }));
            return true;
          },

          uninstall() {
            if (unsubscribe) unsubscribe();
            unsubscribe = null;
            listeners.splice(0).forEach((remove) => remove());
            if (flushTimer) clearTimeout(flushTimer);
            flushTimer = null;
            const editor = api();
            if (editor) editor.updateScene({ collaborators: new Map(), captureUpdate: "NEVER" });
          },

          knownFileIds() {
            const editor = api();
            return editor ? Object.keys(editor.getFiles() || {}) : [];
          },

          apply(payload) {
            const editor = api();
            if (!editor) return false;
            // Ship our own pending edits first so they are not mistaken for
            // remote ones after the merge.
            if (flushTimer) { clearTimeout(flushTimer); flush(); }
            const state = editor.getAppState();
            const busy = new Set(
              [state.editingTextElement, state.editingElement, state.newElement, state.resizingElement]
                .filter(Boolean).map((el) => el.id),
            );
            const local = editor.getSceneElementsIncludingDeleted();
            const byId = new Map(local.map((el) => [el.id, el]));
            let changed = false;
            for (const remote of payload.elements || []) {
              if (!remote || typeof remote.id !== "string" || busy.has(remote.id)) continue;
              const current = byId.get(remote.id);
              const wins = !current ||
                remote.version > current.version ||
                (remote.version === current.version && remote.versionNonce < current.versionNonce);
              if (wins) {
                byId.set(remote.id, remote);
                synced.set(remote.id, key(remote));
                changed = true;
              }
            }
            const files = Object.values(payload.files || {});
            if (files.length) {
              files.forEach((file) => knownFiles.add(file.id));
              editor.addFiles(files);
            }
            let next = Array.from(byId.values());
            if (next.every((el) => typeof el.index === "string")) {
              next.sort((a, b) => (a.index < b.index ? -1 : a.index > b.index ? 1 : (a.id < b.id ? -1 : 1)));
            } else if (Array.isArray(payload.elementOrder)) {
              const rank = new Map(payload.elementOrder.map((id, i) => [id, i]));
              next.sort((a, b) => (rank.get(a.id) ?? 1e9) - (rank.get(b.id) ?? 1e9));
            }
            if (changed) {
              applying = true;
              try {
                editor.updateScene({ elements: next, captureUpdate: "NEVER" });
              } finally {
                applying = false;
              }
              lastOrder = editor.getSceneElementsIncludingDeleted().map((el) => el.id).join(",");
            }
            return changed;
          },

          setCollaborators(list) {
            const editor = api();
            if (!editor) return;
            const collaborators = new Map();
            for (const c of list || []) {
              const entry = {
                id: c.id,
                username: c.username,
                color: { background: c.color, stroke: c.color },
                isIdle: !!c.isIdle,
              };
              if (c.pointer) {
                entry.pointer = { x: c.pointer.x, y: c.pointer.y, tool: c.pointer.tool || "pointer" };
                entry.button = c.button || "up";
              }
              collaborators.set(c.id, entry);
            }
            editor.updateScene({ collaborators, captureUpdate: "NEVER" });
          },
        };
      })();
    }
    """#
}

/// `WKUserContentController` retains its handlers; this keeps the session
/// releasable even if `stop()` is never reached.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: ExcaliDashLiveSession?

    init(_ target: ExcaliDashLiveSession) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let body = message.body
        MainActor.assumeIsolated {
            target?.receive(body)
        }
    }
}

/// Which ExcaliDash drawings are live right now. While live, the document
/// store's 10 s freshness polling must not reload the canvas (peers' edits
/// already arrive through the socket, and a reload would reset undo).
@MainActor
final class ExcaliDashLiveRegistry {
    static let shared = ExcaliDashLiveRegistry()
    private var sessions: [String: ExcaliDashLiveSession] = [:]

    func isLive(_ reference: CloudStorageDocumentReference) -> Bool {
        sessions[reference.id]?.isReceivingLiveUpdates == true
    }

    /// Runs live collaboration for `reference` until the calling task is
    /// cancelled (the editor closes the drawing).
    func run(reference: CloudStorageDocumentReference, webView: WKWebView) async {
        guard reference.providerID == .excaliDash,
              case .drawing(let drawingID)? = try? ExcaliDashItemID(reference.itemID),
              let (credential, client) = try? await ExcaliDashAuthenticator.shared.liveContext(
                  for: reference.accountID
              ) else { return }
        guard !Task.isCancelled else { return }
        let session = ExcaliDashLiveSession(
            drawingID: drawingID,
            credential: credential,
            client: client,
            webView: webView
        )
        if let previous = sessions[reference.id] { await previous.stop() }
        sessions[reference.id] = session
        await session.start()
        // Park until the editor leaves this drawing.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        await session.stop()
        if sessions[reference.id] === session {
            sessions[reference.id] = nil
        }
    }
}
