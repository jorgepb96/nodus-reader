import Foundation
import GVoiceKit

public enum ReferenceCleanupProvenance {
    public static func merging(_ report: ReferenceCleanupReport, into previous: JSONValue?) throws -> JSONValue {
        let encoded = try JSONEncoder().encode(report)
        let cleanup = try JSONDecoder().decode(JSONValue.self, from: encoded)
        var object: [String: JSONValue]
        switch previous {
        case .object(let existing): object = existing
        case .some(let existing): object = ["previousProvenance": existing]
        case nil: object = [:]
        }
        object["referenceCleanup"] = cleanup
        return .object(object)
    }
}
