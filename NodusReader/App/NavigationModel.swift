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

    public var smartList: SmartList? {
        switch self {
        case .home: .home
        case .allBooks: .allBooks
        case .favorites: .favorites
        case .toRead: .toRead
        case .finished: .finished
        case .inbox: .inbox
        case .collection: nil
        }
    }

    public var title: String {
        switch self {
        case .collection: "Collection"
        default: smartList?.title ?? "Library"
        }
    }
}

@MainActor
@Observable
public final class NavigationModel {
    public var phoneTab: AppTab = .home
    public var sidebarSelection: SidebarDestination = .allBooks
    public var columnVisibility: NavigationSplitViewVisibility = .all

    public init() {}

    public func showAllBooks() {
        phoneTab = .library
        sidebarSelection = .allBooks
    }
}

extension FocusedValues {
    /// The navigation of the focused library window, for menu commands.
    @Entry var nodusNavigation: NavigationModel?
}
