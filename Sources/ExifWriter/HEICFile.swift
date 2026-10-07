import Foundation

/// **A HEIC, as far as finding its EXIF and its XMP packet and putting
/// either back a different size.**
///
/// A HEIC is a file of boxes, each a length and a four-letter type. The
/// pictures and the metadata are *items*. One box, `iinf`, says what each
/// item is, and another, `iloc`, says where in the file each item's bytes
/// lie, as offsets from the start of the file. EXIF is the item of type
/// `Exif`: four bytes giving the length of a prefix, the prefix, and then a
/// TIFF structure. The XMP packet is an item of type `mime` that says it
/// holds `application/rdf+xml`.
///
/// Because `iloc` holds file offsets, neither can simply grow. This does
/// what ExifTool does: the item is replaced where it lies, everything after
/// it sits further along, the box it lies in is given its new length, and
/// every offset in `iloc` that pointed past it is moved by the difference.
/// Every other item's bytes are carried across as they were.
///
/// An AVIF is laid out the same way.
enum HEICFile {

    struct Box {
        let type: String
        let start: Int
        /// 8, or 16 where the length is held in 64 bits.
        let header: Int
        let size: Int
        /// The length field says "to the end of the file", so it does not
        /// change when the box grows.
        let toTheEnd: Bool

        var end: Int { start + size }
        var body: Range<Int> { start + header..<end }
    }

    static func boxes(_ bytes: [UInt8], in range: Range<Int>) throws -> [Box] {
        var out: [Box] = []
        var at = range.lowerBound
        while at < range.upperBound {
            guard at + 8 <= range.upperBound else { throw ExifWriterError.malformed("a box cut short") }
            let short = big(bytes, at, 4)
            let type = String(decoding: bytes[at + 4..<at + 8], as: UTF8.self)
            var header = 8
            var size = short
            if short == 1 {
                guard at + 16 <= range.upperBound else { throw ExifWriterError.malformed("a box cut short") }
                header = 16
                size = big(bytes, at + 8, 8)
            } else if short == 0 {
                size = range.upperBound - at
            }
            guard size >= header, at + size <= range.upperBound else {
                throw ExifWriterError.malformed("a box that runs past its parent")
            }
            out.append(Box(type: type, start: at, header: header, size: size, toTheEnd: short == 0))
            at += size
        }
        return out
    }

    // MARK: Where the items lie

    /// The `iloc` box: where each item's bytes are.
    struct Locations: Equatable {
        struct Extent: Equatable {
            var index: Int
            var offset: Int
            var length: Int
        }

        struct Item: Equatable {
            var id: Int
            /// 0 for offsets into the file, which is the only kind moved
            /// here. The whole 16-bit field is kept as it was read.
            var method: Int
            var reference: Int
            var base: Int
            var extents: [Extent]

            var inTheFile: Bool { method & 0x0F == 0 && reference == 0 }
        }

        var version: Int
        var flags: [UInt8]
        var offsetSize: Int
        var lengthSize: Int
        var baseSize: Int
        var indexSize: Int
        var items: [Item]

        /// From the box's body, which is everything after its length and
        /// type.
        init(_ body: [UInt8]) throws {
            var reader = Reader(body)
            version = try reader.take(1)
            flags = try reader.raw(3)
            guard version <= 2 else { throw ExifWriterError.unsupported("an item location box of version \(version)") }
            let sizes = try reader.take(1)
            let more = try reader.take(1)
            offsetSize = sizes >> 4
            lengthSize = sizes & 0x0F
            baseSize = more >> 4
            indexSize = version == 0 ? 0 : more & 0x0F
            let wide = version == 2
            let count = try reader.take(wide ? 4 : 2)
            items = []
            for _ in 0..<count {
                let id = try reader.take(wide ? 4 : 2)
                let method = version == 0 ? 0 : try reader.take(2)
                let reference = try reader.take(2)
                let base = try reader.take(baseSize)
                let extentCount = try reader.take(2)
                var extents: [Extent] = []
                for _ in 0..<extentCount {
                    let index = try reader.take(indexSize)
                    let offset = try reader.take(offsetSize)
                    extents.append(Extent(index: index, offset: offset, length: try reader.take(lengthSize)))
                }
                items.append(Item(id: id, method: method, reference: reference, base: base, extents: extents))
            }
            guard reader.isAtEnd else { throw ExifWriterError.malformed("an item location box with bytes left over") }
            // The low four bits of the second sizes byte are kept in `more`
            // for a version 0 box, where they are reserved.
            reserved = version == 0 ? more & 0x0F : 0
        }

        private var reserved = 0

        /// The box's body again. The same length as it was read at, since
        /// nothing here changes how many items there are or how wide a
        /// field is.
        func body() throws -> [UInt8] {
            var out: [UInt8] = [UInt8(version)] + flags
            out.append(UInt8(offsetSize << 4 | lengthSize))
            out.append(UInt8(baseSize << 4 | (version == 0 ? reserved : indexSize)))
            let wide = version == 2
            out += try HEICFile.bytes(items.count, wide ? 4 : 2)
            for item in items {
                out += try HEICFile.bytes(item.id, wide ? 4 : 2)
                if version != 0 { out += try HEICFile.bytes(item.method, 2) }
                out += try HEICFile.bytes(item.reference, 2)
                out += try HEICFile.bytes(item.base, baseSize)
                out += try HEICFile.bytes(item.extents.count, 2)
                for extent in item.extents {
                    out += try HEICFile.bytes(extent.index, indexSize)
                    out += try HEICFile.bytes(extent.offset, offsetSize)
                    out += try HEICFile.bytes(extent.length, lengthSize)
                }
            }
            return out
        }

        /// **Moves every offset that points at or past `from` by `delta`**:
        /// what sat after the item that changed sits that much further
        /// along.
        mutating func shift(from: Int, by delta: Int) throws {
            for index in items.indices where items[index].inTheFile {
                if items[index].base >= from {
                    items[index].base += delta
                    continue
                }
                for extent in items[index].extents.indices
                where items[index].base + items[index].extents[extent].offset >= from {
                    guard offsetSize > 0 else {
                        throw ExifWriterError.unsupported("item offsets this layout gives no room to move")
                    }
                    items[index].extents[extent].offset += delta
                }
            }
        }
    }

    // MARK: Finding an item

    /// The file as far as its list of items and where they lie.
    private struct Layout {
        let top: [Box]
        let iloc: Box
        var locations: Locations
        let listed: [Listed]
    }

    /// One item as `iinf` lists it.
    private struct Listed {
        let id: Int
        let type: String
        /// What a `mime` item says it holds, and how that is encoded.
        var content = ""
        var encoding = ""
    }

    /// One item's bytes in the file.
    private struct Found {
        var layout: Layout
        /// Which of `layout.locations.items` it is.
        let item: Int
        let payload: Range<Int>
    }

    private static func layout(_ bytes: [UInt8]) throws -> Layout {
        let top = try boxes(bytes, in: 0..<bytes.count)
        guard top.first?.type == "ftyp" else { throw ExifWriterError.notThisFormat("a HEIC") }
        guard let meta = top.first(where: { $0.type == "meta" }) else {
            throw ExifWriterError.notThisFormat("a HEIC")
        }
        guard !top.contains(where: { $0.type == "moov" || $0.type == "moof" }) else {
            throw ExifWriterError.unsupported("a HEIC that holds a sequence of pictures")
        }
        guard meta.body.count >= 4 else { throw ExifWriterError.malformed("an empty meta box") }
        let children = try boxes(bytes, in: meta.body.lowerBound + 4..<meta.end)
        guard let iinf = children.first(where: { $0.type == "iinf" }),
              let iloc = children.first(where: { $0.type == "iloc" }) else {
            throw ExifWriterError.malformed("a HEIC with no list of its items")
        }
        return Layout(top: top, iloc: iloc, locations: try Locations(Array(bytes[iloc.body])),
                      listed: try listed(bytes, iinf))
    }

    private static func listed(_ bytes: [UInt8], _ iinf: Box) throws -> [Listed] {
        guard iinf.body.count >= 6 else { throw ExifWriterError.malformed("an item list cut short") }
        let version = Int(bytes[iinf.body.lowerBound])
        let entries = iinf.body.lowerBound + 4 + (version == 0 ? 2 : 4)
        guard entries <= iinf.end else { throw ExifWriterError.malformed("an item list cut short") }
        var out: [Listed] = []
        for entry in try boxes(bytes, in: entries..<iinf.end) where entry.type == "infe" {
            guard entry.body.count >= 4 else { continue }
            let version = Int(bytes[entry.body.lowerBound])
            // Before version 2 an entry has no type, and so is neither
            // EXIF nor XMP.
            guard version >= 2 else { continue }
            let idSize = version == 2 ? 2 : 4
            var at = entry.body.lowerBound + 4
            guard at + idSize + 2 + 4 <= entry.end else { continue }
            var item = Listed(id: big(bytes, at, idSize),
                              type: String(decoding: bytes[at + idSize + 2..<at + idSize + 6], as: UTF8.self))
            at += idSize + 6
            // Then the item's name, and for a `mime` item what it holds
            // and how that is encoded, each ending in a zero. The last may
            // be left off.
            func text() -> String {
                let end = bytes[at..<entry.end].firstIndex(of: 0) ?? entry.end
                defer { at = min(end + 1, entry.end) }
                return String(decoding: bytes[at..<end], as: UTF8.self)
            }
            _ = text()
            if item.type == "mime" {
                item.content = text()
                item.encoding = text()
            }
            out.append(item)
        }
        return out
    }

    /// Where the item with this id lies. `what` names it in an error.
    private static func find(_ id: Int, _ what: String, in layout: Layout, _ bytes: [UInt8]) throws -> Found {
        guard let item = layout.locations.items.firstIndex(where: { $0.id == id }) else {
            throw ExifWriterError.malformed("\(what) that is listed and not located")
        }
        let located = layout.locations.items[item]
        guard located.inTheFile, located.extents.count == 1 else {
            throw ExifWriterError.unsupported("\(what) held in pieces, or outside the file's own data")
        }
        let start = located.base + located.extents[0].offset
        let payload = start..<start + located.extents[0].length
        guard payload.upperBound <= bytes.count else {
            throw ExifWriterError.malformed("\(what) that lies outside the file")
        }
        return Found(layout: layout, item: item, payload: payload)
    }

    /// The EXIF item, or nil where the file has none.
    private static func exif(_ bytes: [UInt8]) throws -> Found? {
        let layout = try layout(bytes)
        guard let listed = layout.listed.first(where: { $0.type == "Exif" }) else { return nil }
        return try find(listed.id, "EXIF", in: layout, bytes)
    }

    /// The TIFF structure in the EXIF item: what follows four bytes giving
    /// the length of a prefix, and the prefix.
    private static func structure(_ found: Found, _ bytes: [UInt8]) throws -> Range<Int> {
        let start = found.payload.lowerBound
        guard found.payload.count >= 4, 4 + big(bytes, start, 4) + 8 <= found.payload.count else {
            throw ExifWriterError.malformed("EXIF too short to be EXIF")
        }
        return start + 4 + big(bytes, start, 4)..<found.payload.upperBound
    }

    /// The item that holds the XMP packet, or nil where the file has none:
    /// a `mime` item that says it holds RDF. The item's bytes are the
    /// packet and nothing else.
    private static func packet(_ bytes: [UInt8]) throws -> Found? {
        let layout = try layout(bytes)
        guard let listed = layout.listed.first(where: { $0.type == "mime" && $0.content == "application/rdf+xml" })
        else { return nil }
        // One that is compressed cannot be read here, so what it states
        // cannot be known.
        guard listed.encoding.isEmpty else { throw ExifWriterError.unsupported("XMP that is compressed") }
        return try find(listed.id, "XMP", in: layout, bytes)
    }

    // MARK: Reading and writing

    /// The position the HEIC states: its EXIF's, and where that has none,
    /// its XMP packet's.
    static func position(in bytes: [UInt8]) throws -> GPSPosition? {
        if let found = try exif(bytes),
           let stated = try GPSBlock.position(in: ArrayStore(bytes: Array(bytes[try structure(found, bytes)]))) {
            return stated
        }
        guard let found = try packet(bytes) else { return nil }
        return try XMPPacket.position(in: Array(bytes[found.payload]))
    }

    /// The same HEIC with the position set, or with nil taken out, in its
    /// EXIF and in its packet. Nil where there is nothing to change.
    static func setting(_ position: GPSPosition?, in bytes: [UInt8]) throws -> [UInt8]? {
        let described = try settingPacket(position, in: bytes)
        let placed = try settingExif(position, in: described ?? bytes)
        return placed ?? described
    }

    /// The same HEIC with its packet's position changed. Nil where there is
    /// no packet, or it states no position, or it already states this one.
    private static func settingPacket(_ position: GPSPosition?, in bytes: [UInt8]) throws -> [UInt8]? {
        guard let found = try packet(bytes) else { return nil }
        let old = Array(bytes[found.payload])
        guard let new = try XMPPacket.setting(position, in: old), new != old else { return nil }
        return try replacing(found, "XMP", with: new, in: bytes)
    }

    private static func settingExif(_ position: GPSPosition?, in bytes: [UInt8]) throws -> [UInt8]? {
        guard let found = try exif(bytes) else {
            guard position != nil else { return nil }
            throw ExifWriterError.unsupported("a HEIC with no EXIF")
        }
        let tiff = try structure(found, bytes)
        let held = Array(bytes[tiff])
        let edit = try GPSBlock.plan(ArrayStore(bytes: held), setting: position)
        guard !edit.isEmpty || edit.leavesNothing else { return nil }
        // EXIF that said nothing but the position keeps its item, and says
        // nothing: taking an item out of a HEIC is more than this does.
        let structure = edit.leavesNothing ? GPSBlock.empty() : edit.applied(to: held)
        return try replacing(found, "EXIF", with: Array(bytes[found.payload.lowerBound..<tiff.lowerBound]) + structure,
                             in: bytes)
    }

    /// **The file with one item's bytes replaced by `written`**, which may
    /// be longer or shorter: everything after sits that much further along,
    /// the box it lies in is given its new length, and every offset that
    /// pointed past it is moved by the difference.
    private static func replacing(_ found: Found, _ what: String, with written: [UInt8],
                                  in bytes: [UInt8]) throws -> [UInt8] {
        var found = found
        let delta = written.count - found.payload.count

        // The box the item lies in grows with it.
        guard let holder = found.layout.top.first(where: {
            $0.start <= found.payload.lowerBound && found.payload.upperBound <= $0.end
        }), holder.type == "mdat" else {
            throw ExifWriterError.unsupported("\(what) that is not in the file's data box")
        }

        found.layout.locations.items[found.item].extents[0].length = written.count
        try found.layout.locations.shift(from: found.payload.upperBound, by: delta)
        let locations = try found.layout.locations.body()
        guard locations.count == found.layout.iloc.body.count else {
            throw ExifWriterError.malformed("an item location box that does not read back at its own length")
        }

        var out = bytes
        // The two edits that change no lengths are made first, where
        // everything still is. Then the item, which moves what follows it.
        out.replaceSubrange(found.layout.iloc.body, with: locations)
        if !holder.toTheEnd {
            let size = holder.size + delta
            if holder.header == 16 {
                out.replaceSubrange(holder.start + 8..<holder.start + 16, with: try self.bytes(size, 8))
            } else {
                out.replaceSubrange(holder.start..<holder.start + 4, with: try self.bytes(size, 4))
            }
        }
        out.replaceSubrange(found.payload, with: written)
        return out
    }

    // MARK: Numbers

    /// A big-endian number of `count` bytes, which is how every number in
    /// this format is held. Nothing for a count of 0.
    static func big(_ bytes: [UInt8], _ at: Int, _ count: Int) -> Int {
        bytes[at..<at + count].reduce(0) { $0 << 8 | Int($1) }
    }

    static func bytes(_ value: Int, _ count: Int) throws -> [UInt8] {
        guard value >= 0, count == 8 || value >> (8 * count) == 0 else {
            throw ExifWriterError.unsupported("a number too large for the room this file gives it")
        }
        return (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { at == bytes.count }

        mutating func take(_ count: Int) throws -> Int {
            guard at + count <= bytes.count else { throw ExifWriterError.malformed("an item location box cut short") }
            defer { at += count }
            return HEICFile.big(bytes, at, count)
        }

        mutating func raw(_ count: Int) throws -> [UInt8] {
            guard at + count <= bytes.count else { throw ExifWriterError.malformed("an item location box cut short") }
            defer { at += count }
            return Array(bytes[at..<at + count])
        }
    }
}
