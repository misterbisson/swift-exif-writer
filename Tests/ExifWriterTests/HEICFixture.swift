import Foundation
@testable import ExifWriter

/// **A HEIC's boxes built by hand**, to put the EXIF in each place a writer
/// may leave it and hold the offsets in each width the format allows.
///
/// It is not a picture: the item that stands for one is a run of bytes no
/// decoder would take. What is under test is that the EXIF is found and
/// replaced, that every other item's bytes come through, and that the boxes
/// still add up. Whether a real picture survives is asked of the two HEICs
/// ImageIO wrote.
struct HEICFixture {
    /// The TIFF structure the EXIF item holds.
    var exif: [UInt8] = Fixture().bytes()
    /// Put the EXIF after the picture in the data box and not before it.
    var exifLast = false
    /// Put the box that lists the items after the data box.
    var metaLast = false
    /// The version of the box that says where items lie: 0, 1 or 2.
    var version = 1
    /// Offsets counted from a base held per item, and not from the file's
    /// start.
    var based = false
    /// Offsets and lengths in eight bytes each.
    var wide = false
    /// The data box's length held in 64 bits.
    var largeData = false
    /// Leave the EXIF item out altogether.
    var noExif = false

    static let picture: [UInt8] = (0..<180).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) }
    static let notes: [UInt8] = [UInt8]("<x:xmpmeta>a packet that must come through as it was</x:xmpmeta>".utf8)

    /// The EXIF item's bytes: a prefix of six, as Apple writes it.
    var payload: [UInt8] { [0, 0, 0, 6] + [UInt8]("Exif".utf8) + [0, 0] + exif }

    func bytes() -> [UInt8] {
        let ftyp = box("ftyp", [UInt8]("heic".utf8) + [0, 0, 0, 0] + [UInt8]("mif1heic".utf8))
        // The items in the order they lie in the data box.
        var lying: [(id: Int, bytes: [UInt8])] = [(1, Self.picture), (3, Self.notes)]
        if !noExif { lying.insert((2, payload), at: exifLast ? 2 : 0) }

        func meta(_ dataStart: Int) -> [UInt8] {
            var offsets: [Int: (Int, Int)] = [:]
            var at = dataStart
            for item in lying {
                offsets[item.id] = (at, item.bytes.count)
                at += item.bytes.count
            }
            let size = wide ? 8 : 4
            var iloc: [UInt8] = [UInt8(version), 0, 0, 0, UInt8(size << 4 | size), UInt8((based ? 4 : 0) << 4)]
            let ids = lying.map(\.id).sorted()
            iloc += number(ids.count, version == 2 ? 4 : 2)
            for id in ids {
                let (offset, length) = offsets[id]!
                iloc += number(id, version == 2 ? 4 : 2)
                if version != 0 { iloc += [0, 0] }
                iloc += [0, 0]
                if based { iloc += number(dataStart, 4) }
                iloc += [0, 1] + number(based ? offset - dataStart : offset, size) + number(length, size)
            }
            var infe = entry(1, "hvc1") + entry(3, "mime")
            if !noExif { infe += entry(2, "Exif") }
            let iinf = box("iinf", [0, 0, 0, 0] + number(noExif ? 2 : 3, 2) + infe)
            let hdlr = box("hdlr", [0, 0, 0, 0, 0, 0, 0, 0] + [UInt8]("pict".utf8) + [UInt8](repeating: 0, count: 13))
            let pitm = box("pitm", [0, 0, 0, 0, 0, 1])
            let iref = box("iref", [0, 0, 0, 0] + box("cdsc", [0, 2, 0, 1, 0, 1]) + box("cdsc", [0, 3, 0, 1, 0, 1]))
            return box("meta", [0, 0, 0, 0] + hdlr + pitm + iinf + iref + box("iloc", iloc))
        }

        let data = lying.flatMap(\.bytes)
        let dataHeader = largeData ? 16 : 8
        let mdat = largeData
            ? [0, 0, 0, 1] + [UInt8]("mdat".utf8) + number(data.count + 16, 8) + data
            : box("mdat", data)
        // The meta box is the same length wherever the data starts, so it is
        // measured once and then built for the start that length gives.
        let metaLength = meta(0).count
        if metaLast {
            return ftyp + mdat + meta(ftyp.count + dataHeader)
        }
        return ftyp + meta(ftyp.count + metaLength + dataHeader) + mdat
    }

    private func entry(_ id: Int, _ type: String) -> [UInt8] {
        box("infe", [2, 0, 0, 1] + number(id, 2) + [0, 0] + [UInt8](type.utf8) + [0])
    }

    private func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        number(body.count + 8, 4) + [UInt8](type.utf8) + body
    }

    private func number(_ value: Int, _ count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}

extension Read {
    /// A HEIC's items by id, each the bytes the file says are its own.
    static func items(_ bytes: [UInt8]) throws -> [Int: [UInt8]] {
        let top = try HEICFile.boxes(bytes, in: 0..<bytes.count)
        let meta = top.first { $0.type == "meta" }!
        let iloc = try HEICFile.boxes(bytes, in: meta.body.lowerBound + 4..<meta.end).first { $0.type == "iloc" }!
        var out: [Int: [UInt8]] = [:]
        for item in try HEICFile.Locations(Array(bytes[iloc.body])).items where item.inTheFile {
            out[item.id] = item.extents.flatMap { Array(bytes[(item.base + $0.offset)..<(item.base + $0.offset + $0.length)]) }
        }
        return out
    }

    /// The top-level boxes as their type and length, which must add up to
    /// the file.
    static func boxes(_ bytes: [UInt8]) throws -> [(type: String, size: Int)] {
        try HEICFile.boxes(bytes, in: 0..<bytes.count).map { ($0.type, $0.size) }
    }
}
