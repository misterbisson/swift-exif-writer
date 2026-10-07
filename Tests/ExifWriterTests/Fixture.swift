import Foundation
@testable import ExifWriter

/// **A small TIFF built by hand**, so a test knows where every byte is and
/// both byte orders are covered: a grey picture in one strip, a first
/// directory, and a GPS block where one is asked for.
struct Fixture {
    enum Block: Equatable {
        case none
        /// As a camera writes one: the position, and the altitude with it.
        case camera(latitude: Double, longitude: Double, altitude: Double)
        /// A block that says how high and not where.
        case altitudeOnly(Double)
    }

    var little = true
    var block = Block.none
    /// Put the block after the first directory, as the last thing in the
    /// file, where another writer may have left it.
    var blockLast = false
    var width = 6
    var height = 5

    /// The picture: one byte a pixel, each its own value.
    var pixels: [UInt8] { (0..<width * height).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) } }

    func bytes() -> [UInt8] {
        var out: [UInt8] = (little ? [0x49, 0x49] : [0x4D, 0x4D]) + u16(42) + u32(0)
        let strip = out.count
        out += pixels
        if out.count % 2 == 1 { out.append(0) }

        var blockOffset: UInt32?
        if block != .none, !blockLast { blockOffset = UInt32(out.count); out += gpsBlock(at: out.count) }

        var entries: [[UInt8]] = [
            entry(256, 3, 1, short(UInt16(width))), entry(257, 3, 1, short(UInt16(height))),
            entry(258, 3, 1, short(8)), entry(259, 3, 1, short(1)), entry(262, 3, 1, short(1)),
            entry(273, 4, 1, u32(UInt32(strip))), entry(277, 3, 1, short(1)),
            entry(278, 3, 1, short(UInt16(height))), entry(279, 4, 1, u32(UInt32(width * height))),
        ]
        let root = out.count
        let rootLength = 2 + 12 * (entries.count + (block == .none ? 0 : 1)) + 4
        if block != .none {
            entries.append(entry(0x8825, 4, 1, u32(blockOffset ?? UInt32(root + rootLength))))
        }
        out += u16(UInt16(entries.count)) + entries.flatMap { $0 } + u32(0)
        if block != .none, blockLast { out += gpsBlock(at: out.count) }
        out.replaceSubrange(4..<8, with: u32(UInt32(root)))
        return out
    }

    private func gpsBlock(at offset: Int) -> [UInt8] {
        var entries: [[UInt8]] = [entry(0, 1, 4, [2, 2, 0, 0])]
        var values: [UInt8] = []
        var count = 2
        let altitude: Double
        switch block {
        case .none: return []
        case .camera(_, _, let high):
            count = 6
            altitude = high
        case .altitudeOnly(let high): altitude = high
        }
        let valuesAt = offset + 2 + 12 * (count + 1) + 4
        func rationals(_ degrees: Double) -> [UInt8] {
            let total = Int((abs(degrees) * 360_000).rounded())
            return u32(UInt32(total / 360_000)) + u32(1) + u32(UInt32(total % 360_000 / 6000)) + u32(1)
                + u32(UInt32(total % 6000)) + u32(100)
        }
        if case .camera(let latitude, let longitude, _) = block {
            entries.append(entry(1, 2, 2, [latitude < 0 ? 0x53 : 0x4E, 0, 0, 0]))
            entries.append(entry(2, 5, 3, u32(UInt32(valuesAt + values.count))))
            values += rationals(latitude)
            entries.append(entry(3, 2, 2, [longitude < 0 ? 0x57 : 0x45, 0, 0, 0]))
            entries.append(entry(4, 5, 3, u32(UInt32(valuesAt + values.count))))
            values += rationals(longitude)
        }
        entries.append(entry(5, 1, 1, [0, 0, 0, 0]))
        entries.append(entry(6, 5, 1, u32(UInt32(valuesAt + values.count))))
        values += u32(UInt32((altitude * 100).rounded())) + u32(100)
        return u16(UInt16(entries.count)) + entries.flatMap { $0 } + u32(0) + values
    }

    private func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: [UInt8]) -> [UInt8] {
        u16(tag) + u16(type) + u32(count) + value
    }

    /// A 16-bit value as an entry holds one: at the front of its four bytes.
    private func short(_ value: UInt16) -> [UInt8] { u16(value) + [0, 0] }

    private func u16(_ value: UInt16) -> [UInt8] {
        little ? [UInt8(value & 0xFF), UInt8(value >> 8)] : [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private func u32(_ value: UInt32) -> [UInt8] {
        let big = [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        return little ? big.reversed() : big
    }
}

/// What a test reads out of a TIFF beside the position.
enum Read {
    /// The GPS block the first directory points at.
    static func block(_ bytes: [UInt8]) throws -> TIFFStructure.Directory? {
        let tiff = try TIFFStructure(ArrayStore(bytes: bytes))
        let root = try tiff.directory(at: tiff.first)
        guard let pointer = root.entry(TIFFStructure.gpsPointer) else { return nil }
        return try tiff.directory(at: Int(tiff.u32(pointer.value, 0)))
    }

    static func altitude(_ bytes: [UInt8]) throws -> Double? {
        let tiff = try TIFFStructure(ArrayStore(bytes: bytes))
        guard let entry = try block(bytes)?.entry(6), let raw = try tiff.value(of: entry) else { return nil }
        return Double(tiff.u32(raw, 0)) / Double(tiff.u32(raw, 4))
    }

    /// The picture's own bytes, found the way a reader finds them.
    static func pixels(_ bytes: [UInt8]) throws -> [UInt8] {
        let tiff = try TIFFStructure(ArrayStore(bytes: bytes))
        let root = try tiff.directory(at: tiff.first)
        guard let offsets = root.entry(273), let counts = root.entry(279) else { return [] }
        let at = Int(tiff.u32(offsets.value, 0))
        return Array(bytes[at..<at + Int(tiff.u32(counts.value, 0))])
    }
}
