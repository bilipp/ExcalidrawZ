//
//  NewRoomModifier.swift
//  ExcalidrawZ
//
//  Created by Dove Zachary on 3/18/25.
//

import SwiftUI
import Combine

class CollaborationState: ObservableObject {
    @Published var isCreateRoomConfirmationDialogPresented = false
    @Published var isCreateRoomFromFileSheetPresented = false
    @Published var isJoinRoomSheetPresented = false
    
    @Published var isCreateRoomSheetPresented = false
    
    /// Requests to seed a new room from an existing file, sent by the file
    /// context menus and by the create-room file browser. `NewRoomModifier`
    /// is the only subscriber, which keeps loading and error reporting in one
    /// place no matter where the request came from.
    let createRoomFromFilePublisher = PassthroughSubject<CollaborationRoomSource, Never>()

    @AppStorage("userCollaborationName") private var userCollaborationName = ""
    var userCollaborationInfo: CollaborationInfo {
        get {
            CollaborationInfo(username: userCollaborationName)
        }
        set {
            userCollaborationName = newValue.username
        }
    }
    
    func requestCreateRoom(from source: CollaborationRoomSource) {
        createRoomFromFilePublisher.send(source)
    }
}

struct NewRoomModifier: ViewModifier {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.alertToast) private var alertToast
    @EnvironmentObject private var fileState: FileState
    @StateObject private var state = CollaborationState()
    
    func body(content: Content) -> some View {
        content
#if os(iOS)
            .sheet(isPresented: Binding {
                UIDevice.current.userInterfaceIdiom == .pad ? state.isCreateRoomConfirmationDialogPresented : false
            } set: { val in
                if UIDevice.current.userInterfaceIdiom == .pad {
                    state.isCreateRoomConfirmationDialogPresented = val
                }
            }) {
                // Confirmation Dialog will crash on iPadOS
                VStack(spacing: 16) {
                    Text(.localizable(.collaborationNewRoomConfirmationDialogTitle))
                        .font(.title2)
                    Text(.localizable(.collaborationNewRoomConfirmationDialogMessage))
                        .frame(maxWidth: 400)
                        .multilineTextAlignment(.center)
                    
                    VStack(spacing: 8) {
                        Button {
                            state.isCreateRoomConfirmationDialogPresented.toggle()
                            state.isCreateRoomSheetPresented.toggle()
                        } label: {
                            Text(.localizable(.collaborationNewRoomConfirmationDialogButtonCreateBlankRoom))
                                .frame(width: 200)
                        }
                        .buttonStyle(.bordered)
                        
                        Button {
                            state.isCreateRoomConfirmationDialogPresented.toggle()
                            state.isCreateRoomFromFileSheetPresented.toggle()
                        } label: {
                            Text(.localizable(.collaborationNewRoomConfirmationDialogButtonCreateFromFile))
                                .frame(width: 200)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .presentationDetents([.height(300)])
                .padding()
            }
#endif
            .confirmationDialog(
                String(localizable: .collaborationNewRoomConfirmationDialogTitle),
                isPresented: Binding {
#if os(iOS)
                    UIDevice.current.userInterfaceIdiom != .pad ? state.isCreateRoomConfirmationDialogPresented : false
#elseif os(macOS)
                    state.isCreateRoomConfirmationDialogPresented
#endif
                } set: { val in
#if os(iOS)
                    if UIDevice.current.userInterfaceIdiom != .pad {
                        state.isCreateRoomConfirmationDialogPresented = val
                    }
#elseif os(macOS)
                    state.isCreateRoomConfirmationDialogPresented = val
#endif
                },
                titleVisibility: .visible
            ) {
                Button {
                    state.isCreateRoomSheetPresented.toggle()
                } label: {
                    Text(.localizable(.collaborationNewRoomConfirmationDialogButtonCreateBlankRoom))
                }
                Button {
                    state.isCreateRoomFromFileSheetPresented.toggle()
                } label: {
                    Text(.localizable(.collaborationNewRoomConfirmationDialogButtonCreateFromFile))
                }
            } message: {
                Text(.localizable(.collaborationNewRoomConfirmationDialogMessage))
            }
            .sheet(isPresented: $state.isCreateRoomSheetPresented) {
                CreateRoomSheetView { name, isBlank in
                    if isBlank {
                        createRoom(name: name)
                    } else {
                        state.isCreateRoomFromFileSheetPresented.toggle()
                    }
                }
#if os(iOS)
                .presentationDetents([.height(160)])
#endif
            }
            .sheet(isPresented: $state.isCreateRoomFromFileSheetPresented) {
                ExcalidrawFileBrowser { selection in
                    switch selection {
                        case .file(let file):
                            state.requestCreateRoom(from: .file(file))
                        case .localFile(let url):
                            state.requestCreateRoom(from: .localFile(url))
                    }
                }
            }
            .sheet(isPresented: $state.isJoinRoomSheetPresented) {
                JoinRoomSheetView()
#if os(iOS)
                    .presentationDetents([.height(240)])
#endif
            }
            .onReceive(state.createRoomFromFilePublisher) { source in
                Task { await createRoom(from: source) }
            }
            .environmentObject(state)
    }
    
    /// Loads the source file's current contents and opens a room seeded with
    /// them. Each storage kind needs its own read path — a linked folder file
    /// needs its security scope, a cloud file may still have to be fetched.
    @MainActor
    private func createRoom(from source: CollaborationRoomSource) async {
        do {
            let name = source.roomName
            switch source {
                case .file(let file):
                    let content = try await file.loadContent()
                    var excalidrawFile = try ExcalidrawFile(data: content, id: file.id?.uuidString)
                    try await excalidrawFile.syncFiles(context: viewContext)
                    createRoom(name: name, file: excalidrawFile)

                case .localFile(let url):
                    let excalidrawFile = try await LocalFolder.withSecurityScopedAccessToContainingFolder(
                        for: url
                    ) {
                        try ExcalidrawFile(contentsOf: url)
                    }
                    createRoom(name: name, file: excalidrawFile)

                case .temporaryFile(let url):
                    let content = try await fileState.readTemporaryFileContent(at: url)
                    createRoom(name: name, file: try ExcalidrawFile(data: content))

                case .cloudStorageFile(let reference):
                    let content = try await CloudStorageDocumentStore.shared.content(
                        for: reference,
                        checkingRemoteRevision: true
                    )
                    createRoom(name: name, file: try ExcalidrawFile(data: content))
            }
        } catch {
            alertToast(error)
        }
    }

    private func createRoom(name: String, file: ExcalidrawFile = ExcalidrawFile()) {
        Task.detached {
            do {
                let fileID = try await PersistenceController.shared.collaborationFileRepository.createCollaborationFile(
                    name: name,
                    content: file.content,
                    isOwner: true
                )

                await MainActor.run {
                    if let collabFile = viewContext.object(with: fileID) as? CollaborationFile {
                        fileState.setActiveFile(.collaborationFile(collabFile))
                    }
                }
            } catch {
                await alertToast(error)
            }
        }
    }
}


func copyRoomShareLink(roomID: String, filename: String?) {
    // let encodedRoomID = CollabRoomIDCoder.shared.encode(roomID: roomID)
    var url: URL
    let urlString: String
    
//    let scheme = "https" // "excalidrawz"
//    let path = "collab"
        
//    let useExcalidrawScheme = true // Use Excalidraw scheme if needed
//    if useExcalidrawScheme {
        url = URL(string: "https://excalidraw.com/#room=\(roomID)")!
        
        if let filename, !filename.isEmpty, #available(macOS 13.0, *) {
            url.append(queryItems: [
                URLQueryItem(name: "name", value: filename)
            ])
        }
        urlString = url.absoluteString
//    } else if #available(macOS 13.0, *) {
//        url = URL(string: "excalidrawz://collab/\(roomID)")!
//        url.append(queryItems: [
//            URLQueryItem(name: "name", value: filename?.isEmpty == false ? filename : nil)
//        ])
//        urlString = url.absoluteString
//    } else {
//        urlString = "excalidrawz://collab/\(roomID)" + (filename?.isEmpty == false ? "?name=\(filename!)" : "")
//    }
#if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(urlString, forType: .string)
#elseif os(iOS)
    UIPasteboard.general.setObjects([urlString])
#endif
}
