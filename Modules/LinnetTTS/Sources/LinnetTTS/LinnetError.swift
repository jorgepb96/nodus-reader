import CLinnetTTS
import Foundation

/// Error reported by the runtime. The cases follow the C API status codes
/// (`LINNET_ERR_*`); the payload is the runtime's message.
public enum LinnetError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// A value was out of range or an argument was unusable (-1).
    case invalidArgument(String)
    /// A file could not be read (-2).
    case io(String)
    /// The file is not a container the runtime understands (-3).
    case format(String)
    /// The container parsed but the model topology is wrong (-4).
    case shape(String)
    /// An output buffer was too small (-5); the Swift API retries internally, so this is not expected.
    case bufferTooSmall(String)
    /// Internal failure in the runtime (-6), for example a caught panic.
    case internalError(String)

    /// C API status code.
    public var code: Int32 {
        switch self {
        case .invalidArgument: return -1
        case .io: return -2
        case .format: return -3
        case .shape: return -4
        case .bufferTooSmall: return -5
        case .internalError: return -6
        }
    }

    /// Message from the runtime.
    public var message: String {
        switch self {
        case let .invalidArgument(m), let .io(m), let .format(m), let .shape(m), let .bufferTooSmall(m),
             let .internalError(m):
            return m
        }
    }

    public var description: String { "LinnetError(\(code)): \(message)" }
    public var errorDescription: String? { description }

    init(code: Int32, message: String) {
        switch code {
        case -1: self = .invalidArgument(message)
        case -2: self = .io(message)
        case -3: self = .format(message)
        case -4: self = .shape(message)
        case -5: self = .bufferTooSmall(message)
        default: self = .internalError(message)
        }
    }
}

/// Turn a C status into a thrown error, with the runtime's thread-local message.
@inline(__always)
func check(_ status: Int32) throws {
    if status != 0 {
        throw LinnetError(code: status, message: String(cString: linnet_last_error()))
    }
}
