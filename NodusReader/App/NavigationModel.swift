// SPDX-License-Identifier: AGPL-3.0-only
import Observation
import SwiftUI

public enum AppTab: Hashable {
    case home
    case library
    case collections
    case settings
    case search
}

public enum SidebarDestination: Hashable {
    case home
    case allBooks
    case favorites
    case toRead
    case finished
    case inbox
    case collection(UUID)
    /// Settings in the detail column of the iPad and Mac layouts, beside the
    /// sidebar, instead of a sheet or a separate window.
    case settings

    public var smartList: SmartList? {
        switch self {
        case .home: .home
        case .allBooks: .allBooks
        case .favorites: .favorites
        case .toRead: .toRead
        case .finished: .finished
        case .inbox: .inbox
        case .collection, .settings: nil
        }
    }

    public var title: String {
        switch self {
        case .collection: String(localized: "Collection")
        case .settings: String(localized: "Settings")
        default: smartList?.title ?? String(localized: "Library")
        }
    }
}

@MainActor
@Observable
public final class NavigationModel {
    public var phoneTab: AppTab = .home
    public var sidebarSelection: SidebarDestination = .allBooks
    public var columnVisibility: NavigationSplitViewVisibility = .all
    /// A full-screen reader is open. The iPhone and iPad layouts present it
    /// from their own views, so the layout waits for it to close.
    public var openReaders = 0
    public var readerIsOpen: Bool { openReaders > 0 }
    /// The book open in the Mac library window's reader, which replaces the
    /// library in the same window until it is closed.
    public var macReaderBookID: UUID?

    public init() {}

    /// Carries the current place across a switch between the iPhone tabs and
    /// the iPad sidebar (a foldable iPhone opened or closed).
    public func adoptLayout(pad: Bool) {
        if pad {
            switch phoneTab {
            case .home: sidebarSelection = .home
            case .library, .search: sidebarSelection = .allBooks
            case .settings: sidebarSelection = .settings
            case .collections: break
            }
        } else {
            switch sidebarSelection {
            case .home: phoneTab = .home
            case .collection: phoneTab = .collections
            case .settings: phoneTab = .settings
            default: phoneTab = .library
            }
        }
    }

    public func showAllBooks() {
        phoneTab = .library
        sidebarSelection = .allBooks
    }
}

extension EnvironmentValues {
    /// The iPad layout (sidebar, wider measures) is in use: always on iPad, and
    /// on an iPhone whose window is at least 600 pt both ways, such as the
    /// opened iPhone Duo. A Pro Max in landscape (956 × 440) keeps the iPhone
    /// layout, as does the Duo's cover screen (466 × 678).
    @Entry var usesPadLayout: Bool = DeviceInfo.isPad
    /// The window is large enough for the iPad layout right now. Unlike
    /// `usesPadLayout` it changes while a reader is open.
    @Entry var windowFitsPadLayout: Bool = DeviceInfo.isPad
}

extension DeviceInfo {
    static func prefersPadLayout(windowSize: CGSize) -> Bool {
        isPad || min(windowSize.width, windowSize.height) >= 600
    }
}

extension FocusedValues {
    /// The navigation of the focused library window, for menu commands.
    @Entry var nodusNavigation: NavigationModel?
}
