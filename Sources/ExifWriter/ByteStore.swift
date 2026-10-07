import Foundation

/// Bytes that can be read a piece at a time, so a large file is never held
/// in memory whole.
protocol ByteStore {
    var count: Int { get }
    func read(_ offset: Int, _ length: Int) throws -> [UInt8]
}

struct ArrayStore: ByteStore {
    let bytes: [UInt8]

    var count: Int { bytes.count }

    func read(_ offset: Int, _ length: Int) throws -> [UInt8] {
        guard offset >= 0, length >= 0, offset + length <= bytes.count else {
            throw ExifWriterError.malformed("a value lies outside the data")
        }
        return Array(bytes[offset..<offset + length])
    }
}

final class FileStore: ByteStore {
    let handle: FileHandle
    let count: Int

    init(_ handle: FileHandle) throws {
        self.handle = handle
        count = Int(try handle.seekToEnd())
    }

    func read(_ offset: Int, _ length: Int) throws -> [UInt8] {
        guard offset >= 0, length >= 0, offset + length <= count else {
            throw ExifWriterError.malformed("a value lies outside the file")
        }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: length), data.count == length else {
            throw ExifWriterError.malformed("the file ended early")
        }
        return [UInt8](data)
    }
}

/// A store as an edit that has not been made yet would leave it, so a second
/// edit can be planned over the first and the two made as one.
struct EditedStore: ByteStore {
    let base: ByteStore
    let edit: ByteEdit

    private var kept: Int { edit.truncate ?? base.count }
    var count: Int { kept + edit.append.count }

    func read(_ offset: Int, _ length: Int) throws -> [UInt8] {
        let end = offset + length
        guard offset >= 0, length >= 0, end <= count else {
            throw ExifWriterError.malformed("a value lies outside the data")
        }
        var out: [UInt8] = []
        if offset < kept { out += try base.read(offset, min(end, kept) - offset) }
        if end > kept { out += edit.append[max(offset, kept) - kept..<end - kept] }
        for patch in edit.patches {
            let low = max(patch.offset, offset)
            let high = min(patch.offset + patch.bytes.count, end)
            guard low < high else { continue }
            out.replaceSubrange(low - offset..<high - offset,
                                with: patch.bytes[low - patch.offset..<high - patch.offset])
        }
        return out
    }
}

/// **What a write does to the bytes**, worked out before anything is
/// touched: cut the end off, add to the end, then overwrite a few bytes.
///
/// The order matters to a file edited in place. What is new is written at
/// the end first, and the few bytes that point at it are changed last, so a
/// write that is interrupted leaves the old structure standing.
struct ByteEdit: Equatable {
    struct Patch: Equatable {
        var offset: Int
        var bytes: [UInt8]
    }

    /// The length to cut back to first, where the block being replaced is
    /// the last thing in the store.
    var truncate: Int?
    var append: [UInt8] = []
    var patches: [Patch] = []
    /// The structure would be left with nothing in it. Nothing is planned,
    /// and whoever holds the structure removes it whole.
    var leavesNothing = false

    var isEmpty: Bool { truncate == nil && append.isEmpty && patches.isEmpty }

    /// **This edit and then `next` as one edit**, where `next` was planned
    /// over what this one leaves. `count` is the length before either.
    func then(_ next: ByteEdit, over count: Int) -> ByteEdit {
        let kept = truncate ?? count
        var out = ByteEdit(truncate: truncate, append: append + next.append, patches: patches + next.patches)
        if let cut = next.truncate {
            // The second edit cuts into what the first one left.
            out.truncate = cut < kept ? cut : truncate
            out.append = (cut < kept ? [] : Array(append[..<(cut - kept)])) + next.append
            // A patch the cut runs through keeps what lies before it.
            out.patches = patches.filter { $0.offset < cut }
                .map { Patch(offset: $0.offset, bytes: Array($0.bytes.prefix(cut - $0.offset))) } + next.patches
        }
        return out
    }

    func applied(to bytes: [UInt8]) -> [UInt8] {
        var out = truncate.map { Array(bytes[..<$0]) } ?? bytes
        out += append
        for patch in patches {
            out.replaceSubrange(patch.offset..<patch.offset + patch.bytes.count, with: patch.bytes)
        }
        return out
    }

    func apply(to handle: FileHandle) throws {
        if let truncate { try handle.truncate(atOffset: UInt64(truncate)) }
        if !append.isEmpty {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(append))
            try handle.synchronize()
        }
        for patch in patches {
            try handle.seek(toOffset: UInt64(patch.offset))
            try handle.write(contentsOf: Data(patch.bytes))
        }
        try handle.synchronize()
    }
}
