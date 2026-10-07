import Foundation

/// **A PNG, as far as its chunks**, the one chunk that holds EXIF and the
/// one that holds the XMP packet.
///
/// A PNG is a signature and then chunks, each a length, a four-letter type,
/// its data and a checksum. Nothing in it is an offset into the file, so a
/// chunk can grow, or a new one go in, and everything after it simply sits
/// further along. EXIF is the `eXIf` chunk, whose data is a TIFF structure
/// from its first byte. The XMP packet is the text of an `iTXt` chunk whose
/// keyword is `XML:com.adobe.xmp`.
///
/// Every chunk but those two is carried across as the bytes it was, and the
/// packet's chunk is too unless the packet states a position.
enum PNGFile {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let exif = [UInt8]("eXIf".utf8)
    private static let data = [UInt8]("IDAT".utf8)
    private static let text = [UInt8]("iTXt".utf8)
    private static let keyword = [UInt8]("XML:com.adobe.xmp".utf8) + [0]

    struct Chunk {
        let type: [UInt8]
        /// Where the chunk starts, at its length.
        let start: Int
        let data: Range<Int>
        /// One past the chunk's checksum.
        var end: Int { data.upperBound + 4 }
    }

    static func chunks(_ bytes: [UInt8]) throws -> [Chunk] {
        guard bytes.count >= 8, Array(bytes[..<8]) == signature else {
            throw ExifWriterError.notThisFormat("a PNG")
        }
        var out: [Chunk] = []
        var at = 8
        while at < bytes.count {
            guard at + 12 <= bytes.count else { throw ExifWriterError.malformed("a PNG chunk cut short") }
            let length = Int(TIFFStructure.u32(bytes, at, false))
            let chunk = Chunk(type: Array(bytes[at + 4..<at + 8]), start: at, data: at + 8..<at + 8 + length)
            guard chunk.end <= bytes.count else { throw ExifWriterError.malformed("a PNG chunk cut short") }
            out.append(chunk)
            at = chunk.end
        }
        return out
    }

    /// The position the PNG states: its EXIF's, and where that has none,
    /// its XMP packet's.
    static func position(in bytes: [UInt8]) throws -> GPSPosition? {
        let chunks = try chunks(bytes)
        return try exifPosition(in: bytes, chunks) ?? packetPosition(in: bytes, chunks)
    }

    /// What the EXIF states and what the packet states, apart.
    static func positions(in bytes: [UInt8]) throws -> StatedPositions {
        let chunks = try chunks(bytes)
        return StatedPositions(exif: try exifPosition(in: bytes, chunks), xmp: try packetPosition(in: bytes, chunks))
    }

    private static func exifPosition(in bytes: [UInt8], _ chunks: [Chunk]) throws -> GPSPosition? {
        guard let chunk = chunks.first(where: { $0.type == exif }) else { return nil }
        return try GPSBlock.position(in: ArrayStore(bytes: Array(bytes[chunk.data])))
    }

    private static func packetPosition(in bytes: [UInt8], _ chunks: [Chunk]) throws -> GPSPosition? {
        guard let packet = try packet(in: bytes, chunks) else { return nil }
        return try XMPPacket.position(in: Array(bytes[packet.text]))
    }

    /// The same PNG with the position set, or with nil taken out, in its
    /// EXIF and in its packet. Nil where there is nothing to change.
    static func setting(_ position: GPSPosition?, in bytes: [UInt8]) throws -> [UInt8]? {
        let described = try settingPacket(position, in: bytes)
        let placed = try settingExif(position, in: described ?? bytes)
        return placed ?? described
    }

    /// The chunk that holds the XMP packet, and where in it the packet
    /// lies: after the keyword, two bytes that say whether it is
    /// compressed, and two more pieces of text nothing uses.
    private static func packet(in bytes: [UInt8], _ chunks: [Chunk]) throws -> (chunk: Chunk, text: Range<Int>)? {
        for chunk in chunks where chunk.type == text && bytes[chunk.data].starts(with: keyword) {
            var at = chunk.data.lowerBound + keyword.count
            guard at + 2 <= chunk.data.upperBound else { throw ExifWriterError.malformed("an XMP chunk cut short") }
            // The format lets the text be compressed and XMP asks that it
            // is not. One that is cannot be read here, so what it states
            // cannot be known.
            guard bytes[at] == 0 else { throw ExifWriterError.unsupported("XMP that is compressed") }
            at += 2
            for _ in 0..<2 {
                guard let zero = bytes[at..<chunk.data.upperBound].firstIndex(of: 0) else {
                    throw ExifWriterError.malformed("an XMP chunk cut short")
                }
                at = zero + 1
            }
            return (chunk, at..<chunk.data.upperBound)
        }
        return nil
    }

    /// The same PNG with its packet's position changed. Nil where there is
    /// no packet, or it states no position, or it already states this one.
    private static func settingPacket(_ position: GPSPosition?, in bytes: [UInt8]) throws -> [UInt8]? {
        guard let packet = try packet(in: bytes, try chunks(bytes)) else { return nil }
        let old = Array(bytes[packet.text])
        guard let new = try XMPPacket.setting(position, in: old), new != old else { return nil }
        let written = chunk(text, Array(bytes[packet.chunk.data.lowerBound..<packet.text.lowerBound]) + new)
        return Array(bytes[..<packet.chunk.start]) + written + Array(bytes[packet.chunk.end...])
    }

    private static func settingExif(_ position: GPSPosition?, in bytes: [UInt8]) throws -> [UInt8]? {
        let chunks = try chunks(bytes)
        let picture = chunks.first { $0.type == data }
        if let chunk = chunks.first(where: { $0.type == exif }) {
            let held = Array(bytes[chunk.data])
            let edit = try GPSBlock.plan(ArrayStore(bytes: held), setting: position)
            let without = Array(bytes[..<chunk.start]) + Array(bytes[chunk.end...])
            // The EXIF said nothing but the position: the chunk goes whole.
            if edit.leavesNothing { return without }
            guard !edit.isEmpty else { return nil }
            let written = self.chunk(exif, edit.applied(to: held))
            // **EXIF after the picture's data is moved before it.** The
            // format allows either and asks for before, some readers miss
            // it after, and ExifTool moves it too whenever it writes.
            let at = picture.map { min($0.start, chunk.start) } ?? chunk.start
            return Array(without[..<at]) + written + Array(without[at...])
        }
        guard let position else { return nil }
        // No EXIF at all: a new chunk, before the picture's data, which is
        // where the format asks for it.
        guard let first = picture else {
            throw ExifWriterError.malformed("a PNG with no picture data")
        }
        let seed = GPSBlock.seed()
        let held = try GPSBlock.plan(ArrayStore(bytes: seed), setting: position).applied(to: seed)
        return Array(bytes[..<first.start]) + chunk(exif, held) + Array(bytes[first.start...])
    }

    /// A chunk as it is written: length, type, data, and the checksum over
    /// the type and the data.
    static func chunk(_ type: [UInt8], _ data: [UInt8]) -> [UInt8] {
        let body = type + data
        return big(UInt32(data.count)) + body + big(crc(body))
    }

    private static func big(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    }

    /// The CRC-32 every PNG chunk ends with.
    static func crc(_ bytes: [UInt8]) -> UInt32 {
        ~bytes.reduce(0xFFFF_FFFF) { crc, byte in table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
}
