import Foundation
@testable import ExifWriter

/// **A small PNG built by hand**: a grey picture, a text chunk and a
/// resolution chunk to stand for whatever else a file carries, and EXIF where
/// it is asked for.
struct PNGFixture {
    enum Exif {
        case none
        /// A TIFF structure to hold as the file's EXIF.
        case holding([UInt8])
    }

    var exif = Exif.none
    /// Put the EXIF after the picture's data, where the format also allows
    /// it and some writers leave it.
    var exifLast = false
    /// An XMP packet, held as the format holds one.
    var packet: [UInt8]?
    /// Say the packet's chunk is compressed, which this library cannot
    /// read.
    var packetCompressed = false
    var width = 6
    var height = 5

    var pixels: [UInt8] { (0..<width * height).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) } }

    func bytes() -> [UInt8] {
        var out = PNGFile.signature
        out += PNGFile.chunk(tag("IHDR"), big(UInt32(width)) + big(UInt32(height)) + [8, 0, 0, 0, 0])
        out += PNGFile.chunk(tag("pHYs"), big(11811) + big(11811) + [1])
        out += PNGFile.chunk(tag("tEXt"), [UInt8]("Comment".utf8) + [0] + [UInt8]("kept as it was".utf8))
        if let packet {
            let flags: [UInt8] = [packetCompressed ? 1 : 0, 0, 0, 0]
            out += PNGFile.chunk(tag("iTXt"), [UInt8]("XML:com.adobe.xmp".utf8) + [0] + flags + packet)
        }
        if case .holding(let held) = exif, !exifLast { out += PNGFile.chunk(tag("eXIf"), held) }
        // Split in two, as a real encoder splits a picture's data.
        let stream = zlib(scanlines)
        out += PNGFile.chunk(tag("IDAT"), Array(stream[..<(stream.count / 2)]))
        out += PNGFile.chunk(tag("IDAT"), Array(stream[(stream.count / 2)...]))
        if case .holding(let held) = exif, exifLast { out += PNGFile.chunk(tag("eXIf"), held) }
        out += PNGFile.chunk(tag("IEND"), [])
        return out
    }

    /// Each row behind a filter byte of 0, which is no filter.
    private var scanlines: [UInt8] {
        (0..<height).flatMap { row in [0] + pixels[(row * width)..<((row + 1) * width)] }
    }

    /// A zlib stream holding `data` stored and not compressed, which is
    /// legal and needs no compressor.
    private func zlib(_ data: [UInt8]) -> [UInt8] {
        let length = UInt16(data.count)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return [0x78, 0x01, 0x01, UInt8(length & 0xFF), UInt8(length >> 8),
                UInt8(~length & 0xFF), UInt8(~length >> 8)] + data + big(b << 16 | a)
    }

    private func tag(_ name: String) -> [UInt8] { [UInt8](name.utf8) }

    private func big(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

extension Read {
    /// A PNG's chunks as their type and their whole bytes, in order.
    static func chunks(_ bytes: [UInt8]) throws -> [(type: String, bytes: [UInt8])] {
        try PNGFile.chunks(bytes).map {
            (String(decoding: $0.type, as: UTF8.self), Array(bytes[$0.start..<$0.end]))
        }
    }

    /// Every chunk but the EXIF, which is what a write must leave alone.
    static func otherChunks(_ bytes: [UInt8]) throws -> [[UInt8]] {
        try chunks(bytes).filter { $0.type != "eXIf" }.map(\.bytes)
    }

    /// Every chunk but the EXIF and the XMP packet, which is what a write
    /// must leave alone in a file whose packet states a position.
    static func chunksBesideMetadata(_ bytes: [UInt8]) throws -> [[UInt8]] {
        try chunks(bytes).filter { $0.type != "eXIf" && $0.type != "iTXt" }.map(\.bytes)
    }

    /// The XMP packet: the text of the chunk that holds one.
    static func packet(png bytes: [UInt8]) throws -> [UInt8]? {
        let lead = [UInt8]("XML:com.adobe.xmp".utf8) + [0, 0, 0, 0, 0]
        return try PNGFile.chunks(bytes).first { $0.type == [UInt8]("iTXt".utf8) }
            .map { Array(bytes[$0.data].dropFirst(lead.count)) }
    }

    static func exif(_ bytes: [UInt8]) throws -> [UInt8]? {
        try PNGFile.chunks(bytes).first { $0.type == [UInt8]("eXIf".utf8) }.map { Array(bytes[$0.data]) }
    }
}
