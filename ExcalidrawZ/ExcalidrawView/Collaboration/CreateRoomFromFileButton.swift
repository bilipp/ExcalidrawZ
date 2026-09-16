//
//  CreateRoomFromFileButton.swift
//  ExcalidrawZ
//
//  Created by Philipp Bischoff on 9/16/26.
//

import SwiftUI

/// An existing file that can seed a new collaboration room.
///
/// Every case maps onto a `FileState.ActiveFile`, so the room inherits the
/// name the user already sees for that file instead of a generated one.
enum CollaborationRoomSource: Hashable {
    /// A file in the app's own library.
    case file(File)
    /// A file inside a linked folder.
    case localFile(URL)
    /// A file opened from outside the app.
    case temporaryFile(URL)
    /// A file inside a linked cloud storage location.
    case cloudStorageFile(CloudStorageDocumentReference)

    var activeFile: FileState.ActiveFile {
        switch self {
            case .file(let file):
                .file(file)
            case .localFile(let url):
                .localFile(url)
            case .temporaryFile(let url):
                .temporaryFile(url)
            case .cloudStorageFile(let reference):
                .cloudStorageFile(reference)
        }
    }

    var roomName: String {
        let name = activeFile.name
        return name?.isEmpty == false ? name! : String(localizable: .generalUntitled)
    }
}

/// Menu item that turns an existing file into a new collaboration room seeded
/// with that file's contents.
///
/// The actual work happens in `NewRoomModifier`, so every entry point shares
/// one loading, activation and error-reporting path.
struct CreateRoomFromFileButton: View {
    @Environment(\.alert) private var alert
    @EnvironmentObject private var collaborationState: CollaborationState

    var source: CollaborationRoomSource

    init(source: CollaborationRoomSource) {
        self.source = source
    }

    init(file: File) {
        self.source = .file(file)
    }

    init(localFile url: URL) {
        self.source = .localFile(url)
    }

    init(temporaryFile url: URL) {
        self.source = .temporaryFile(url)
    }

    init(cloudStorageFile reference: CloudStorageDocumentReference) {
        self.source = .cloudStorageFile(reference)
    }

    var body: some View {
        Button {
            // Mirrors `CollaborationFileRow`: a room cannot be joined without
            // a display name, so ask for one before creating anything.
            guard !collaborationState.userCollaborationInfo.username.isEmpty else {
                alert(title: .localizable(.collaborationAlertNameRequiredTitle)) {
                    Text(.localizable(.collaborationAlertNameRequiredMessage))
                }
                return
            }
            collaborationState.requestCreateRoom(from: source)
        } label: {
            Label(
                .localizable(.collaborationButtonCreateRoomFromFile),
                systemSymbol: .doorLeftHandOpen
            )
        }
    }
}
