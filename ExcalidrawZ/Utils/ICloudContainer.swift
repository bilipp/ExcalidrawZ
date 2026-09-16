//
//  ICloudContainer.swift
//  ExcalidrawZ
//

import Foundation

/// The iCloud container this build is signed for.
///
/// The value comes from the `ICLOUD_CONTAINER` build setting (see
/// `Config/Project.xcconfig`), which also fills in the container in
/// `ExcalidrawZ.entitlements`. Reading it from Info.plist keeps the code, the
/// entitlements, and the signing configuration on the same identifier when the
/// project is built with a different development team.
enum ICloudContainer {
    static let identifier: String = {
        if let identifier = Bundle.main.object(forInfoDictionaryKey: "ICloudContainerIdentifier") as? String,
           !identifier.isEmpty,
           !identifier.hasPrefix("$(") {
            return identifier
        }
        return "iCloud.com.chocoford.excalidraw"
    }()
}
