// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum ImportError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case fileAccessDenied(String)
    case unreadableDocument(String)
    case emptyDocument(String)
    case fileTooLarge(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name):
            "“\(name)” is not a supported document format."
        case .fileAccessDenied(let name):
            "Nodus Reader could not read “\(name)”."
        case .unreadableDocument(let name):
            "“\(name)” could not be opened. The file may be damaged or protected."
        case .emptyDocument(let name):
            "“\(name)” does not contain readable text."
        case .fileTooLarge(let name):
            "“\(name)” is too large to import safely on this device."
        case .cancelled:
            "The import was cancelled."
        }
    }
}
