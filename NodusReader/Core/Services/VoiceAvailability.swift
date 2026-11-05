// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

extension ModelManager.Engine {
    var isEnabled: Bool {
        #if os(iOS)
        return self != .qwen && self != .ming
        #else
        return self != .system
        #endif
    }
}

extension ModelManager {
    static var systemModels: [Model] {
        #if os(iOS)
        return [Model(id: "ios-system", engine: .system, name: String(localized: "iOS voices"),
          detail: String(localized: "Start listening without downloading anything. Very fast, with less natural voices."),
          language: "", sizeText: String(localized: "No download required"), license: "Apple",
          source: URL(string: "https://www.apple.com/legal/sla/")!, voices: [], availability: .available, downloadable: false)]
        #else
        return []
        #endif
    }
}
