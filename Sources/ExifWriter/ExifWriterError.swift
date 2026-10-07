import Foundation

public enum ExifWriterError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The bytes are not the format they were said to be.
    case notThisFormat(String)
    /// The format is right and its structure is broken.
    case malformed(String)
    /// The file is sound, and it is laid out in a way this library does not
    /// write. Nothing was changed.
    case unsupported(String)

    public var description: String {
        switch self {
        case .notThisFormat(let what): "not \(what)"
        case .malformed(let what): "malformed: \(what)"
        case .unsupported(let what): "unsupported: \(what)"
        }
    }
}
