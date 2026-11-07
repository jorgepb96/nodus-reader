// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// "Powered by <model> · <licence>" for the voice that narrates: the model's name
/// links to its page (model card or repository, which carries the licence and its
/// attributions) and the licence to its official text.
struct ModelCredit: Equatable {
    let name: String
    let source: URL?
    let license: String
    let licenseURL: URL?

    init(model: ModelManager.Model) {
        name = model.name
        license = model.license
        // iOS voices come with the system: nothing to link.
        source = model.engine == .system ? nil : model.source
        licenseURL = Self.licenseURL(for: model.license, source: model.source)
    }

    /// Standard licences link to their official text; a model's own licence to the
    /// model's page, where it is published.
    static func licenseURL(for license: String, source: URL) -> URL? {
        switch license {
        case "Apple": nil
        case "Apache-2.0": URL(string: "https://www.apache.org/licenses/LICENSE-2.0")
        case "MIT": URL(string: "https://opensource.org/license/mit")
        case "CC BY-NC 4.0": URL(string: "https://creativecommons.org/licenses/by-nc/4.0/")
        case "CC BY 4.0": URL(string: "https://creativecommons.org/licenses/by/4.0/")
        default: source
        }
    }
}
