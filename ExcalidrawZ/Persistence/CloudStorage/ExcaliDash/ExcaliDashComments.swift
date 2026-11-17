//
//  ExcaliDashComments.swift
//  ExcalidrawZ
//
//  Comment threads on an ExcaliDash drawing, as in the ExcaliDash web editor:
//  a thread is a root comment pinned to a scene position plus flat replies.
//  Anyone who can open the drawing may post; the author or the drawing's
//  owner may move or delete; editors and the author may resolve.
//
//  Threads live on the server (`/drawings/:id/comments`). The realtime
//  socket only announces `comments-changed`, after which clients refetch.
//  Pins are drawn by a script inside the editor page so they follow the
//  canvas's scroll and zoom frame by frame; the thread list and composer are
//  native (`ExcaliDashCommentsInspectorContent`).
//

import Foundation
import Logging
import WebKit

struct ExcaliDashComment: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let drawingId: String
    /// Nil for a thread's first comment; otherwise that comment's id.
    let parentId: String?
    let authorUserId: String?
    let authorName: String
    let body: String
    /// Scene coordinates of the pin (0 on replies, which reuse the root's).
    var x: Double
    var y: Double
    var resolvedAt: Date?
    let createdAt: Date?
    let updatedAt: Date?

    var isResolved: Bool { resolvedAt != nil }
}

struct ExcaliDashCommentThread: Identifiable, Hashable, Sendable {
    var root: ExcaliDashComment
    var replies: [ExcaliDashComment]

    var id: String { root.id }

    /// Replies whose root is missing (deleted between fetches) are dropped.
    static func group(_ comments: [ExcaliDashComment]) -> [ExcaliDashCommentThread] {
        var threads: [String: ExcaliDashCommentThread] = [:]
        var order: [String] = []
        for comment in comments where comment.parentId == nil {
            threads[comment.id] = .init(root: comment, replies: [])
            order.append(comment.id)
        }
        for comment in comments {
            guard let parentID = comment.parentId else { continue }
            threads[parentID]?.replies.append(comment)
        }
        return order
            .compactMap { threads[$0] }
            .sorted { ($0.root.createdAt ?? .distantPast) < ($1.root.createdAt ?? .distantPast) }
    }
}

private struct ExcaliDashCommentList: Decodable {
    let comments: [ExcaliDashComment]
}

@MainActor
final class ExcaliDashCommentsModel: ObservableObject {
    enum AccessLevel: String {
        case none, view, edit, owner
    }

    private static let handlerName = "excalidashComments"

    let drawingID: String
    let currentUserID: String
    private let client: ExcaliDashAPIClient
    private weak var webView: WKWebView?
    private let logger = Logger(label: "ExcaliDashComments")

    @Published private(set) var comments: [ExcaliDashComment] = []
    @Published private(set) var accessLevel: AccessLevel = .view
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var showResolved = false {
        didSet { Task { await pushPins() } }
    }
    @Published private(set) var isPlacing = false
    /// Scene position of the pin being written, before it is posted.
    @Published private(set) var draftPoint: CGPoint?
    @Published var activeThreadID: String? {
        didSet {
            guard oldValue != activeThreadID else { return }
            Task { await pushPins() }
        }
    }
    @Published var errorMessage: String?
    /// Bumped when a pin is clicked on the canvas, so the editor can bring
    /// the comments inspector forward.
    @Published private(set) var revealRequest = 0

    private var isPageReady = false
    private var isStopped = false
    private var refreshTask: Task<Void, Never>?
    private var needsAnotherRefresh = false

    init(
        drawingID: String,
        currentUserID: String,
        client: ExcaliDashAPIClient,
        webView: WKWebView
    ) {
        self.drawingID = drawingID
        self.currentUserID = currentUserID
        self.client = client
        self.webView = webView
    }

    // MARK: - Derived state

    var threads: [ExcaliDashCommentThread] {
        ExcaliDashCommentThread.group(comments)
    }

    var visibleThreads: [ExcaliDashCommentThread] {
        showResolved ? threads : threads.filter { !$0.root.isResolved }
    }

    var openThreadCount: Int {
        comments.filter { $0.parentId == nil && !$0.isResolved }.count
    }

    var resolvedThreadCount: Int {
        comments.filter { $0.parentId == nil && $0.isResolved }.count
    }

    var canComment: Bool { accessLevel != .none }

    private var canEdit: Bool { accessLevel == .edit || accessLevel == .owner }

    private func isMine(_ comment: ExcaliDashComment) -> Bool {
        comment.authorUserId != nil && comment.authorUserId == currentUserID
    }

    func canDelete(_ comment: ExcaliDashComment) -> Bool {
        accessLevel == .owner || isMine(comment)
    }

    func canMove(_ comment: ExcaliDashComment) -> Bool {
        accessLevel == .owner || isMine(comment)
    }

    func canResolve(_ thread: ExcaliDashCommentThread) -> Bool {
        canEdit || isMine(thread.root)
    }

    // MARK: - Lifecycle

    func start() async {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.handlerName)
        controller.add(
            WeakScriptMessageHandler { [weak self] body in self?.receive(body) },
            name: Self.handlerName
        )

        async let access: Void = loadAccessLevel()
        refresh()

        for _ in 0..<60 where !isStopped {
            if (try? await webView.callAsyncJavaScript(
                Self.pageScript + "\nreturn window.__exdComments.install();",
                arguments: [:],
                contentWorld: .page
            )) as? Bool == true {
                isPageReady = true
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        await access
        await pushPins()
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        refreshTask?.cancel()
        if let webView {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
            _ = try? await webView.callAsyncJavaScript(
                "window.__exdComments && window.__exdComments.uninstall();",
                arguments: [:],
                contentWorld: .page
            )
        }
    }

    /// Fallback for servers whose socket this client cannot join: poll.
    func pollWhile(isLive: @escaping @MainActor () -> Bool) async {
        while !Task.isCancelled, !isStopped {
            try? await Task.sleep(for: .seconds(isLive() ? 120 : 20))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    // MARK: - Server

    /// Coalesces bursts of `comments-changed` into at most one request in
    /// flight plus one queued behind it.
    func refresh() {
        guard !isStopped else { return }
        if refreshTask != nil {
            needsAnotherRefresh = true
            return
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.needsAnotherRefresh = false
                await self.fetch()
            } while self.needsAnotherRefresh && !Task.isCancelled
            self.refreshTask = nil
        }
    }

    private func fetch() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await client.get("drawings/\(drawingID)/comments", operation: .download)
            let list = try ExcaliDashAPIClient.decode(ExcaliDashCommentList.self, from: data)
            guard !isStopped else { return }
            comments = list.comments
            hasLoaded = true
            if let activeThreadID, !comments.contains(where: { $0.id == activeThreadID }) {
                self.activeThreadID = nil
            }
            await pushPins()
        } catch {
            // A failed refresh keeps the last known threads; the next change
            // notification or poll reconciles them.
            logger.warning("Loading comments failed: \(error.localizedDescription)")
            if !hasLoaded { errorMessage = Self.describe(error) }
        }
    }

    private func loadAccessLevel() async {
        guard let data = try? await client.get("drawings/\(drawingID)", operation: .download),
              let summary = try? ExcaliDashAPIClient.decode(ExcaliDashDrawingSummary.self, from: data) else { return }
        if let raw = summary.accessLevel, let level = AccessLevel(rawValue: raw) {
            accessLevel = level
        } else if summary.userId == currentUserID {
            accessLevel = .owner
        }
    }

    @discardableResult
    func postDraft(_ body: String) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let draftPoint, !text.isEmpty else { return false }
        do {
            let created = try await mutate(
                "POST", "drawings/\(drawingID)/comments",
                ["body": text, "x": Double(draftPoint.x), "y": Double(draftPoint.y)]
            )
            if let created { upsert(created) }
            self.draftPoint = nil
            activeThreadID = created?.id
            await pushPins()
            return true
        } catch {
            errorMessage = "Could not post your comment. \(Self.describe(error))"
            return false
        }
    }

    @discardableResult
    func reply(to thread: ExcaliDashCommentThread, body: String) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        do {
            if let created = try await mutate(
                "POST", "drawings/\(drawingID)/comments",
                ["body": text, "parentId": thread.root.id]
            ) {
                upsert(created)
            }
            await pushPins()
            return true
        } catch {
            errorMessage = "Could not post your reply. \(Self.describe(error))"
            return false
        }
    }

    func setResolved(_ thread: ExcaliDashCommentThread, _ resolved: Bool) async {
        do {
            if let updated = try await mutate(
                "PATCH", "drawings/\(drawingID)/comments/\(thread.root.id)",
                ["resolved": resolved]
            ) {
                upsert(updated)
            }
            if resolved, activeThreadID == thread.id, !showResolved { activeThreadID = nil }
            await pushPins()
        } catch {
            errorMessage = "Could not update this thread. \(Self.describe(error))"
        }
    }

    func delete(_ comment: ExcaliDashComment) async {
        do {
            try await client.delete("drawings/\(drawingID)/comments/\(comment.id)", operation: .deleteItem)
            comments.removeAll { $0.id == comment.id || $0.parentId == comment.id }
            if comment.parentId == nil, activeThreadID == comment.id { activeThreadID = nil }
            await pushPins()
        } catch {
            errorMessage = "Could not delete this comment. \(Self.describe(error))"
        }
    }

    /// Re-anchors a thread's pin. Shown at once and rolled back on failure:
    /// a pin that snapped back for a round trip would feel broken.
    private func move(threadID: String, to point: CGPoint) async {
        guard let index = comments.firstIndex(where: { $0.id == threadID }) else { return }
        let original = comments[index]
        guard canMove(original) else {
            await pushPins()
            return
        }
        comments[index].x = point.x
        comments[index].y = point.y
        do {
            if let updated = try await mutate(
                "PATCH", "drawings/\(drawingID)/comments/\(threadID)",
                ["x": Double(point.x), "y": Double(point.y)]
            ) {
                upsert(updated)
            }
        } catch {
            if let index = comments.firstIndex(where: { $0.id == threadID }) {
                comments[index] = original
            }
            errorMessage = "Could not move this comment. \(Self.describe(error))"
        }
        await pushPins()
    }

    private func mutate(_ method: String, _ path: String, _ json: [String: Any]) async throws -> ExcaliDashComment? {
        let data = try await client.send(method, path, json: json, operation: .updateFile)
        return try? ExcaliDashAPIClient.decode(ExcaliDashComment.self, from: data)
    }

    private func upsert(_ comment: ExcaliDashComment) {
        if let index = comments.firstIndex(where: { $0.id == comment.id }) {
            comments[index] = comment
        } else {
            comments.append(comment)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? CloudStorageError {
            switch error {
                case .permissionDenied:
                    return "You are not allowed to do that here, or this server does not let apps use comments yet (it needs the API key route update)."
                case .authenticationRequired:
                    return "The server refused the app's credentials for comments. If you signed in with SSO, the server needs the API key route update."
                default:
                    break
            }
        }
        return error.localizedDescription
    }

    // MARK: - Canvas

    func startPlacing() {
        activeThreadID = nil
        draftPoint = nil
        isPlacing = true
        Task { await call("window.__exdComments && window.__exdComments.setPlacing(true);") }
    }

    func cancelPlacing() {
        isPlacing = false
        draftPoint = nil
        Task {
            await call("window.__exdComments && window.__exdComments.setPlacing(false);")
            await pushPins()
        }
    }

    /// Scrolls the canvas so the thread's pin is centred.
    func reveal(_ thread: ExcaliDashCommentThread) {
        activeThreadID = thread.id
        Task {
            await call(
                "window.__exdComments && window.__exdComments.focus(x, y);",
                ["x": thread.root.x, "y": thread.root.y]
            )
        }
    }

    private func pushPins() async {
        guard isPageReady, !isStopped else { return }
        let pins: [[String: Any]] = visibleThreads.map { thread in
            [
                "id": thread.id,
                "x": thread.root.x,
                "y": thread.root.y,
                "label": Self.initials(thread.root.authorName),
                "count": thread.replies.count + 1,
                "resolved": thread.root.isResolved,
                "movable": canMove(thread.root),
                "title": "\(thread.root.authorName): \(thread.root.body)",
            ]
        }
        var arguments: [String: Any] = [
            "pins": pins,
            "active": activeThreadID ?? NSNull(),
            "draft": NSNull(),
        ]
        if let draftPoint {
            arguments["draft"] = ["x": Double(draftPoint.x), "y": Double(draftPoint.y)]
        }
        await call(
            "window.__exdComments && window.__exdComments.render(pins, active, draft);",
            arguments
        )
    }

    private func call(_ script: String, _ arguments: [String: Any] = [:]) async {
        guard let webView else { return }
        do {
            _ = try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
        } catch {
            logger.debug("Comment pin script failed: \(error.localizedDescription)")
        }
    }

    private static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    // MARK: - Page → native

    private func receive(_ body: Any) {
        guard !isStopped,
              let message = body as? [String: Any],
              let type = message["type"] as? String else { return }
        switch type {
            case "select":
                guard let id = message["id"] as? String else { return }
                activeThreadID = id
                revealRequest += 1
            case "place":
                guard isPlacing,
                      let x = message["x"] as? Double,
                      let y = message["y"] as? Double else { return }
                isPlacing = false
                draftPoint = CGPoint(x: x, y: y)
                revealRequest += 1
                Task { await pushPins() }
            case "move":
                guard let id = message["id"] as? String,
                      let x = message["x"] as? Double,
                      let y = message["y"] as? Double else { return }
                Task { await move(threadID: id, to: CGPoint(x: x, y: y)) }
            case "cancel":
                if isPlacing || draftPoint != nil {
                    cancelPlacing()
                } else {
                    activeThreadID = nil
                }
            default:
                break
        }
    }

    // MARK: - Page script

    /// Draws pins in a layer inside Excalidraw's container, between the
    /// canvases (z 1–2) and the UI layer (z 4), and repositions them on every
    /// scroll/zoom change. The layer only takes clicks while placing a pin.
    static let pageScript = #"""
    (() => {
      if (window.__exdComments) return;
      const post = (m) => window.webkit?.messageHandlers?.excalidashComments?.postMessage(m);
      const api = () => window.excalidrawZHelper && window.excalidrawZHelper._api;
      const DRAG_THRESHOLD = 3;
      let layer = null, unsubscribe = null, frame = 0;
      let pins = [], active = null, draft = null, placing = false;
      let drag = null;

      const viewport = () => {
        const s = api().getAppState();
        const zoom = typeof s.zoom === "number" ? s.zoom : (s.zoom && s.zoom.value) || 1;
        return { scrollX: s.scrollX || 0, scrollY: s.scrollY || 0, zoom: zoom > 0 ? zoom : 1,
                 width: s.width || window.innerWidth, height: s.height || window.innerHeight };
      };
      const toCanvas = (p, v) => ({ x: (p.x + v.scrollX) * v.zoom, y: (p.y + v.scrollY) * v.zoom });
      const toScene = (p, v) => ({ x: p.x / v.zoom - v.scrollX, y: p.y / v.zoom - v.scrollY });
      const localPoint = (event) => {
        const r = layer.getBoundingClientRect();
        return { x: event.clientX - r.left, y: event.clientY - r.top };
      };

      const style = document.createElement("style");
      style.textContent = `
        .exd-comments { position:absolute; inset:0; z-index:3; pointer-events:none; overflow:hidden; }
        .exd-comments.placing { pointer-events:auto; cursor:crosshair; }
        .exd-pin { position:absolute; transform:translate(-50%,-100%); pointer-events:auto; cursor:pointer;
          min-width:26px; height:26px; padding:0 6px; box-sizing:border-box; border-radius:13px 13px 13px 2px;
          background:#6965db; color:#fff; font:600 11px/26px -apple-system,system-ui,sans-serif;
          text-align:center; box-shadow:0 1px 4px rgba(0,0,0,.3); border:2px solid #fff; user-select:none;
          -webkit-user-select:none; touch-action:none; white-space:nowrap; }
        .exd-pin.resolved { background:#868e96; opacity:.75; }
        .exd-pin.active { background:#e8590c; transform:translate(-50%,-100%) scale(1.15); z-index:1; }
        .exd-pin.draft { background:#e8590c; opacity:.85; pointer-events:none; }
        .exd-pin .count { font-weight:500; opacity:.85; margin-left:3px; }
        .exd-comments.placing .exd-pin { pointer-events:none; }
      `;

      const render = () => {
        frame = 0;
        if (!layer || !api()) return;
        const v = viewport();
        const shown = drag && drag.moved ? pins.map((p) => p.id === drag.id ? { ...p, x: drag.scene.x, y: drag.scene.y } : p) : pins;
        const existing = new Map([...layer.querySelectorAll(".exd-pin[data-id]")].map((n) => [n.dataset.id, n]));
        for (const pin of shown) {
          let node = existing.get(pin.id);
          existing.delete(pin.id);
          if (!node) {
            node = document.createElement("div");
            node.className = "exd-pin";
            node.dataset.id = pin.id;
            node.addEventListener("pointerdown", onPinDown);
            node.addEventListener("pointermove", onPinMove);
            node.addEventListener("pointerup", onPinUp);
            node.addEventListener("pointercancel", onPinCancel);
            layer.appendChild(node);
          }
          const at = toCanvas(pin, v);
          node.style.left = at.x + "px";
          node.style.top = at.y + "px";
          node.title = pin.title || "";
          node.classList.toggle("resolved", !!pin.resolved);
          node.classList.toggle("active", pin.id === active);
          node.dataset.movable = pin.movable ? "1" : "";
          const html = pin.label + (pin.count > 1 ? `<span class="count">${pin.count}</span>` : "");
          if (node.innerHTML !== html) node.innerHTML = html;
        }
        existing.forEach((node) => node.remove());
        let draftNode = layer.querySelector(".exd-pin.draft");
        if (draft) {
          if (!draftNode) {
            draftNode = document.createElement("div");
            draftNode.className = "exd-pin draft";
            draftNode.textContent = "+";
            layer.appendChild(draftNode);
          }
          const at = toCanvas(draft, v);
          draftNode.style.left = at.x + "px";
          draftNode.style.top = at.y + "px";
        } else if (draftNode) {
          draftNode.remove();
        }
      };
      const schedule = () => { if (!frame) frame = requestAnimationFrame(render); };

      // Text labels must not be HTML: initials come from user names.
      const escape = (t) => String(t).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

      function onPinDown(event) {
        if (event.button !== 0 || placing) return;
        event.stopPropagation();
        event.preventDefault();
        const id = event.currentTarget.dataset.id;
        const pin = pins.find((p) => p.id === id);
        if (!pin) return;
        event.currentTarget.setPointerCapture(event.pointerId);
        drag = { id, pointerId: event.pointerId, originX: event.clientX, originY: event.clientY,
                 origin: { x: pin.x, y: pin.y }, scene: { x: pin.x, y: pin.y }, movable: event.currentTarget.dataset.movable === "1", moved: false };
      }
      function onPinMove(event) {
        if (!drag || drag.pointerId !== event.pointerId || !drag.movable) return;
        const dx = event.clientX - drag.originX, dy = event.clientY - drag.originY;
        if (!drag.moved && Math.hypot(dx, dy) < DRAG_THRESHOLD) return;
        drag.moved = true;
        // Move by the pointer's travel so the pin keeps its grab offset.
        const zoom = viewport().zoom;
        drag.scene = { x: drag.origin.x + dx / zoom, y: drag.origin.y + dy / zoom };
        schedule();
      }
      function onPinUp(event) {
        if (!drag || drag.pointerId !== event.pointerId) return;
        const finished = drag;
        drag = null;
        if (finished.moved) {
          const pin = pins.find((p) => p.id === finished.id);
          if (pin) { pin.x = finished.scene.x; pin.y = finished.scene.y; }
          post({ type: "move", id: finished.id, x: finished.scene.x, y: finished.scene.y });
        } else {
          active = finished.id;
          post({ type: "select", id: finished.id });
        }
        schedule();
      }
      function onPinCancel() { drag = null; schedule(); }

      const onLayerClick = (event) => {
        if (!placing) return;
        event.stopPropagation();
        event.preventDefault();
        const scene = toScene(localPoint(event), viewport());
        placing = false;
        layer.classList.remove("placing");
        draft = scene;
        schedule();
        post({ type: "place", x: scene.x, y: scene.y });
      };
      const onKey = (event) => {
        if (event.key === "Escape" && (placing || draft || active)) post({ type: "cancel" });
      };

      window.__exdComments = {
        install() {
          const a = api();
          const host = document.querySelector(".excalidraw");
          if (!a || !host) return false;
          if (layer && layer.isConnected) return true;
          if (!style.isConnected) document.head.appendChild(style);
          layer = document.createElement("div");
          layer.className = "exd-comments";
          layer.addEventListener("pointerdown", (e) => { if (placing) { e.stopPropagation(); } }, true);
          layer.addEventListener("click", onLayerClick);
          host.appendChild(layer);
          unsubscribe = a.onChange(() => schedule());
          window.addEventListener("resize", schedule);
          window.addEventListener("keydown", onKey);
          schedule();
          return true;
        },
        render(nextPins, nextActive, nextDraft) {
          pins = (nextPins || []).map((p) => ({ ...p, label: escape(p.label) }));
          active = nextActive || null;
          draft = nextDraft || null;
          if (draft) { placing = false; layer && layer.classList.remove("placing"); }
          schedule();
        },
        setPlacing(on) {
          placing = !!on;
          if (placing) draft = null;
          layer && layer.classList.toggle("placing", placing);
          schedule();
        },
        focus(x, y) {
          const a = api();
          if (!a) return;
          const v = viewport();
          a.updateScene({ appState: { scrollX: v.width / (2 * v.zoom) - x, scrollY: v.height / (2 * v.zoom) - y } });
          schedule();
        },
        uninstall() {
          if (unsubscribe) unsubscribe();
          unsubscribe = null;
          window.removeEventListener("resize", schedule);
          window.removeEventListener("keydown", onKey);
          if (layer) layer.remove();
          layer = null;
          style.remove();
          delete window.__exdComments;
        },
      };
    })();
    """#
}

/// The comment models of the ExcaliDash drawings open right now, keyed by
/// document reference id, so the inspector can find the active one.
@MainActor
final class ExcaliDashCommentsRegistry: ObservableObject {
    static let shared = ExcaliDashCommentsRegistry()

    @Published private(set) var models: [String: ExcaliDashCommentsModel] = [:]

    func model(for reference: CloudStorageDocumentReference) -> ExcaliDashCommentsModel? {
        models[reference.id]
    }

    func register(_ model: ExcaliDashCommentsModel, for referenceID: String) {
        models[referenceID] = model
    }

    func unregister(_ model: ExcaliDashCommentsModel, for referenceID: String) {
        if models[referenceID] === model { models[referenceID] = nil }
    }
}
