// SPDX-License-Identifier: AGPL-3.0-only
#if os(macOS) && DEBUG
import AppKit
import SwiftUI

/// Development only (`-NodusCaptureScreens` with `-NodusSampleLibrary`): walks
/// the main Mac windows and writes a PNG of each one, drawn by the app itself,
/// for comparison with `design/screens/`. No screen-recording or automation
/// permission is involved.
@MainActor
enum MacScreenCapture {
    /// Set while the tour opens a PDF in Intelligent Reading.
    static var opensPDFInIntelligentReading = false

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NodusCaptures", isDirectory: true)
    }

    static func tour(navigation: NavigationModel, books: () -> [Book], collections: () -> [LibraryCollection]) async {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSLog("NodusCaptures: %@", directory.path)

        for _ in 0..<60 where books().count < 8 { await pause(1) }
        await pause(2)
        navigation.sidebarSelection = .home
        await pause(2)
        capture("01-Home")
        navigation.sidebarSelection = .allBooks
        await pause(2)
        capture("02-AllBooks")
        if let collection = collections().first(where: { $0.name == "Literature" }) {
            navigation.sidebarSelection = .collection(collection.id)
            await pause(2)
            capture("03-Collection")
        }
        navigation.sidebarSelection = .allBooks
        if let book = books().first(where: { $0.title == "Moby-Dick" }) {
            navigation.macReaderBookID = book.id
            await pause(5)
            capture("04-ReaderEPUB")
            navigation.macReaderBookID = nil
        }
        if let pdf = books().first(where: { $0.format == .pdf }) {
            navigation.macReaderBookID = pdf.id
            await pause(8)
            capture("05-ReaderPDF")
            navigation.macReaderBookID = nil
            await pause(1)
            opensPDFInIntelligentReading = true
            navigation.macReaderBookID = pdf.id
            await pause(12)
            capture("06-ReaderPDFIntelligent")
            opensPDFInIntelligentReading = false
            navigation.macReaderBookID = nil
        }
        navigation.sidebarSelection = .settings
        await pause(3)
        capture("07-Settings")
        NSLog("NodusCaptures: done")
        NSApp.terminate(nil)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Every visible window, including its title bar and toolbar.
    private static func capture(_ label: String) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.width > 200 {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let title = window.title.isEmpty ? "window" : window.title.replacingOccurrences(of: "/", with: "-")
            try? data.write(to: directory.appendingPathComponent("\(label)-\(index)-\(title).png"))
        }
    }
}
#endif
