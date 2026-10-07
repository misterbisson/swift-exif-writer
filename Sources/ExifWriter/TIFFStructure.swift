import Foundation

/// **A TIFF structure, read as far as its directories**: the byte order, and
/// the lists of tags that point at everything else.
///
/// A TIFF file is one. So is the EXIF held inside a PNG, a HEIC or a JPEG,
/// which is a small TIFF of its own with offsets counted from its first
/// byte. Offset 0 of the store is the structure's first byte either way.
struct TIFFStructure {
    static let gpsPointer: UInt16 = 0x8825

    /// One tag in a directory. `value` is the four bytes the entry holds:
    /// the value itself where it fits, and otherwise where it is.
    struct Entry: Equatable {
        var tag: UInt16
        var type: UInt16
        var count: UInt32
        var value: [UInt8]

        /// Bytes one item of this type takes, or nil for a type this
        /// library does not know.
        var itemSize: Int? {
            switch type {
            case 1, 2, 6, 7: 1
            case 3, 8: 2
            case 4, 9, 11, 13: 4
            case 5, 10, 12: 8
            default: nil
            }
        }

        /// Bytes the whole value takes, or nil for an unknown type.
        var size: Int? { itemSize.map { $0 * Int(count) } }

        /// The value lies elsewhere and the entry holds its offset.
        var isOutOfLine: Bool { (size ?? 0) > 4 }
    }

    struct Directory {
        let offset: Int
        var entries: [Entry]
        var next: UInt32

        /// Bytes the directory itself takes: a count, the entries, and the
        /// offset of the directory after it.
        var length: Int { 2 + 12 * entries.count + 4 }

        func index(of tag: UInt16) -> Int? { entries.firstIndex { $0.tag == tag } }
        func entry(_ tag: UInt16) -> Entry? { entries.first { $0.tag == tag } }

        /// Where entry `index` keeps its four value bytes.
        func valueOffset(of index: Int) -> Int { offset + 2 + 12 * index + 8 }
    }

    let store: ByteStore
    let littleEndian: Bool
    /// Where the first directory is.
    let first: Int

    init(_ store: ByteStore) throws {
        guard store.count >= 8 else { throw ExifWriterError.notThisFormat("a TIFF structure") }
        let header = try store.read(0, 8)
        switch (header[0], header[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: throw ExifWriterError.notThisFormat("a TIFF structure")
        }
        self.store = store
        let magic = Self.u16(header, 2, littleEndian)
        guard magic != 43 else { throw ExifWriterError.unsupported("BigTIFF") }
        guard magic == 42 else { throw ExifWriterError.notThisFormat("a TIFF structure") }
        first = Int(Self.u32(header, 4, littleEndian))
    }

    func directory(at offset: Int) throws -> Directory {
        guard offset >= 8 else { throw ExifWriterError.malformed("a directory inside the header") }
        let count = Int(u16(try store.read(offset, 2), 0))
        let raw = try store.read(offset + 2, 12 * count + 4)
        let entries = (0..<count).map { index in
            let at = 12 * index
            return Entry(tag: u16(raw, at), type: u16(raw, at + 2), count: u32(raw, at + 4),
                         value: Array(raw[at + 8..<at + 12]))
        }
        return Directory(offset: offset, entries: entries, next: u32(raw, 12 * count))
    }

    /// The bytes of a value, wherever it lies. Nil for an unknown type.
    func value(of entry: Entry) throws -> [UInt8]? {
        guard let size = entry.size else { return nil }
        if size <= 4 { return Array(entry.value[..<size]) }
        return try store.read(Int(u32(entry.value, 0)), size)
    }

    // MARK: Numbers

    func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 { Self.u16(bytes, at, littleEndian) }
    func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 { Self.u32(bytes, at, littleEndian) }

    func bytes(_ value: UInt16) -> [UInt8] {
        littleEndian ? [UInt8(value & 0xFF), UInt8(value >> 8)] : [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    func bytes(_ value: UInt32) -> [UInt8] {
        let big = [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        return littleEndian ? big.reversed() : big
    }

    func bytes(_ entry: Entry) -> [UInt8] {
        bytes(entry.tag) + bytes(entry.type) + bytes(entry.count) + entry.value
    }

    /// A directory as it is written: the count, the entries in the order
    /// given, and the offset of the one after it.
    func bytes(of entries: [Entry], next: UInt32) -> [UInt8] {
        bytes(UInt16(entries.count)) + entries.flatMap(bytes) + bytes(next)
    }

    static func u16(_ bytes: [UInt8], _ at: Int, _ little: Bool) -> UInt16 {
        little ? UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
               : UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    static func u32(_ bytes: [UInt8], _ at: Int, _ little: Bool) -> UInt32 {
        let b = (0..<4).map { UInt32(bytes[at + $0]) }
        return little ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24
                      : b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
    }
}
