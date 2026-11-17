//
//  ExcaliDashCommentsInspectorContent.swift
//  ExcalidrawZ
//
//  Inspector tab listing the comment threads of the open ExcaliDash drawing.
//  Pins on the canvas are drawn by `ExcaliDashCommentsModel`'s page script;
//  clicking one selects its thread here.
//

import SwiftUI
import Combine

struct ExcaliDashCommentsInspectorContent: View {
    @EnvironmentObject private var fileState: FileState
    @EnvironmentObject private var layoutState: LayoutState
    @EnvironmentObject private var appPreference: AppPreference
    @ObservedObject private var registry = ExcaliDashCommentsRegistry.shared

    private var model: ExcaliDashCommentsModel? {
        guard case .cloudStorageFile(let reference) = fileState.currentActiveFile else { return nil }
        return registry.model(for: reference)
    }

    var body: some View {
#if os(macOS)
        if appPreference.inspectorLayout == .sidebar {
            content
                .toolbar {
                    InspectorHeaderToolbar(
                        title: "Comments",
                        isInspectorPresented: layoutState.isInspectorPresented
                    )
                }
        } else {
            content
        }
#else
        content
#endif
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            ExcaliDashCommentsPanel(model: model)
                .id(model.drawingID)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Comments are available for drawings stored on an ExcaliDash server.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ExcaliDashCommentsPanel: View {
    @ObservedObject var model: ExcaliDashCommentsModel

    @State private var draftText = ""
    @State private var isPosting = false
    @FocusState private var isDraftFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.isPlacing {
                placingBanner
            } else if model.draftPoint != nil {
                draftComposer
            }
            if let message = model.errorMessage {
                errorBanner(message)
            }
            threadList
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .watch(value: model.draftPoint) { point in
            if point != nil { isDraftFocused = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.openThreadCount == 1 ? "1 open thread" : "\(model.openThreadCount) open threads")
                    .font(.headline)
                if model.resolvedThreadCount > 0 {
                    Toggle(isOn: $model.showResolved) {
                        Text("Show \(model.resolvedThreadCount) resolved")
                            .font(.caption)
                    }
#if os(macOS)
                    .toggleStyle(.checkbox)
#endif
                    .controlSize(.small)
                }
            }
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                if model.isPlacing || model.draftPoint != nil {
                    model.cancelPlacing()
                } else {
                    draftText = ""
                    model.startPlacing()
                }
            } label: {
                Label("New Comment", systemImage: "plus.bubble")
            }
            .disabled(!model.canComment)
            .help("Click this, then click on the canvas where the comment should go")
        }
    }

    private var placingBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.tap")
            Text("Click on the canvas where the comment should go.")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel") { model.cancelPlacing() }
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var draftComposer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("Add a comment…", text: $draftText, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .focused($isDraftFocused)
                .onSubmit(postDraft)
            HStack {
                Button("Cancel") {
                    draftText = ""
                    model.cancelPlacing()
                }
                Button("Post", action: postDraft)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isPosting || draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func postDraft() {
        guard !isPosting else { return }
        isPosting = true
        Task {
            if await model.postDraft(draftText) { draftText = "" }
            isPosting = false
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Threads

    @ViewBuilder
    private var threadList: some View {
        let threads = model.visibleThreads
        if threads.isEmpty {
            VStack(spacing: 6) {
                Spacer(minLength: 24)
                Image(systemName: "text.bubble")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text(model.hasLoaded ? "No comments yet." : "Loading comments…")
                    .foregroundStyle(.secondary)
                if model.hasLoaded, model.canComment {
                    Text("Use New Comment to pin feedback to a spot on the canvas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(threads) { thread in
                            ExcaliDashCommentThreadCard(
                                model: model,
                                thread: thread,
                                isActive: model.activeThreadID == thread.id
                            )
                            .id(thread.id)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .watch(value: model.activeThreadID) { id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

private struct ExcaliDashCommentThreadCard: View {
    @ObservedObject var model: ExcaliDashCommentsModel
    let thread: ExcaliDashCommentThread
    let isActive: Bool

    @State private var replyText = ""
    @State private var isSending = false
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                commentRow(thread.root)
                Spacer(minLength: 4)
                actions
            }
            ForEach(thread.replies) { reply in
                HStack(alignment: .firstTextBaseline) {
                    commentRow(reply)
                    Spacer(minLength: 4)
                    if model.canDelete(reply) {
                        Button {
                            Task { await model.delete(reply) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Delete reply")
                    }
                }
                .padding(.leading, 12)
            }
            if isActive, model.canComment, !thread.root.isResolved {
                replyComposer
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor.opacity(0.6) : .clear)
        )
        .opacity(thread.root.isResolved ? 0.7 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.reveal(thread) }
        .confirmationDialog(
            "Delete this thread?",
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete Thread", role: .destructive) {
                Task { await model.delete(thread.root) }
            }
        } message: {
            Text("The comment and its \(thread.replies.count) replies are removed for everyone.")
        }
    }

    private func commentRow(_ comment: ExcaliDashComment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(comment.authorName)
                    .font(.subheadline.weight(.semibold))
                if let date = comment.createdAt {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(comment.body)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if model.canResolve(thread) {
                Button {
                    Task { await model.setResolved(thread, !thread.root.isResolved) }
                } label: {
                    Image(systemName: thread.root.isResolved ? "arrow.uturn.backward.circle" : "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .help(thread.root.isResolved ? "Reopen" : "Resolve")
            }
            Menu {
                Button("Show on Canvas") { model.reveal(thread) }
                if model.canDelete(thread.root) {
                    Divider()
                    Button("Delete Thread…", role: .destructive) { isConfirmingDelete = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(.borderless)
        }
        .foregroundStyle(.secondary)
    }

    private var replyComposer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Reply…", text: $replyText, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderless)
            .disabled(isSending || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func send() {
        guard !isSending else { return }
        isSending = true
        Task {
            if await model.reply(to: thread, body: replyText) { replyText = "" }
            isSending = false
        }
    }
}

/// Brings the comments tab forward when a pin is clicked or placed on the
/// canvas of the drawing this editor shows.
struct ExcaliDashCommentsRevealModifier: ViewModifier {
    @EnvironmentObject private var layoutState: LayoutState
    @ObservedObject private var registry = ExcaliDashCommentsRegistry.shared

    let referenceID: String?

    private var revealRequests: AnyPublisher<Int, Never> {
        guard let referenceID, let model = registry.models[referenceID] else {
            return Empty().eraseToAnyPublisher()
        }
        return model.$revealRequest.dropFirst().eraseToAnyPublisher()
    }

    func body(content: Content) -> some View {
        content.onReceive(revealRequests) { _ in
            guard !(layoutState.isInspectorPresented && layoutState.activeInspectorTab == .comments) else { return }
            layoutState.activeInspectorTab = .comments
            layoutState.isInspectorPresented = true
        }
    }
}

/// Number of open threads, shown on the comments tab button.
struct ExcaliDashCommentsCountBadge: View {
    @ObservedObject private var registry = ExcaliDashCommentsRegistry.shared
    let referenceID: String

    var body: some View {
        if let model = registry.models[referenceID] {
            Badge(model: model)
        }
    }

    private struct Badge: View {
        @ObservedObject var model: ExcaliDashCommentsModel

        var body: some View {
            if model.openThreadCount > 0 {
                Text(model.openThreadCount > 99 ? "99+" : "\(model.openThreadCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Capsule().fill(Color.accentColor))
                    .allowsHitTesting(false)
            }
        }
    }
}
