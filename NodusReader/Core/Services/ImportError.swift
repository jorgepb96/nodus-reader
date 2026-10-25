// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum ImportError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case fileAccessDenied(String)
    case unreadableDocument(String)
    case emptyDocument(String)
    case fileTooLarge(String)
    case providerUnavailable(String)
    case drmProtected(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name):
            String(localized: "“\(name)” is not a supported document format.")
        case .fileAccessDenied(let name):
            String(localized: "Nodus Reader could not read “\(name)”.")
        case .unreadableDocument(let name):
            String(localized: "“\(name)” could not be opened. The file may be damaged or protected.")
        case .emptyDocument(let name):
            String(localized: "“\(name)” does not contain readable text.")
        case .fileTooLarge(let name):
            String(localized: "“\(name)” is too large to import safely on this device.")
        case .providerUnavailable(let name):
            String(localized: "“\(name)” could not be read from where it is stored. If it is in iCloud Drive or another cloud service, open it once in Files so it downloads to this device, then import it again.")
        case .drmProtected(let name):
            String(localized: "“\(name)” is protected with DRM. Nodus Reader does not remove DRM; import a DRM-free copy of the book.")
        case .cancelled:
            String(localized: "The import was cancelled.")
        }
    }
}
