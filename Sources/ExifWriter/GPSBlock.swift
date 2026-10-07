import Foundation

/// **The GPS block of a TIFF structure**: reading the position out of it, and
/// planning the bytes that put one in or take one out.
///
/// ## Nothing that is already there moves
///
/// A TIFF structure is full of offsets counted from its first byte, and not
/// all of them are in places a general reader can find: a camera maker's own
/// notes hold some. So this never rebuilds the structure. It writes a new
/// GPS block at the end and changes the four bytes that point at the block.
/// Where the first directory has no such pointer, a copy of that directory
/// with one added goes at the end too, and the four bytes in the header that
/// point at the directory change. Every other byte stays where it was.
///
/// What is replaced stays in the bytes, unreferenced. This is a writer, not
/// a scrubber: a position that was removed can still be found by somebody
/// reading the bytes by hand, unless the block was the last thing in the
/// store, in which case it is cut off.
///
/// ## A second write does not grow the file
///
/// A block this wrote is the last thing in the store. Writing again cuts it
/// off and writes the new one in the same place, so moving a photograph a
/// hundred times costs what moving it once did.
///
/// ## Only the position changes
///
/// The four tags that are the position: latitude, longitude and the letter
/// that signs each. Altitude, the time of the fix, the direction the camera
/// faced and the rest are carried into the new block as they were.
enum GPSBlock {
    private static let version: UInt16 = 0
    private static let latitudeRef: UInt16 = 1
    private static let latitude: UInt16 = 2
    private static let longitudeRef: UInt16 = 3
    private static let longitude: UInt16 = 4
    private static let position: ClosedRange<UInt16> = 1...4

    private typealias Entry = TIFFStructure.Entry
    private typealias Directory = TIFFStructure.Directory

    // MARK: Reading

    /// The position the structure states, or nil where it states none.
    static func position(in store: ByteStore) throws -> GPSPosition? {
        let tiff = try TIFFStructure(store)
        guard let block = block(in: tiff, under: try tiff.directory(at: tiff.first)) else { return nil }

        func axis(_ tag: UInt16, signedBy ref: UInt16, negative: Character) throws -> Double? {
            guard let entry = block.entry(tag), entry.type == 5 || entry.type == 10,
                  (1...3).contains(entry.count), let raw = try tiff.value(of: entry) else { return nil }
            let signed = entry.type == 10
            func number(_ at: Int) -> Double {
                let bits = tiff.u32(raw, at)
                return signed ? Double(Int32(bitPattern: bits)) : Double(bits)
            }
            let pairs = (0..<Int(entry.count)).map { (number(8 * $0), number(8 * $0 + 4)) }
            guard let magnitude = GPSPosition.degrees(pairs) else { return nil }
            let letter = try block.entry(ref)
                .flatMap { $0.type == 2 ? try tiff.value(of: $0)?.first : nil }
                .map { Character(UnicodeScalar($0)).uppercased() }
            return letter == String(negative) ? -abs(magnitude) : magnitude
        }

        guard let latitude = try axis(latitude, signedBy: latitudeRef, negative: "S"),
              let longitude = try axis(longitude, signedBy: longitudeRef, negative: "W") else { return nil }
        return GPSPosition(latitude: latitude, longitude: longitude)
    }

    // MARK: Writing

    /// The bytes that set the position, or with nil take it out.
    ///
    /// An empty plan means there is nothing to do: taking a position out of
    /// a structure that has none.
    static func plan(_ store: ByteStore, setting place: GPSPosition?) throws -> ByteEdit {
        let tiff = try TIFFStructure(store)
        let root = try tiff.directory(at: tiff.first)
        let pointer = root.entries.firstIndex(where: isPointer)
        let old = block(in: tiff, under: root)
        let had = old?.entries.contains { position.contains($0.tag) } ?? false
        guard place != nil || had else { return ByteEdit() }

        var plan = ByteEdit()
        var end = store.count
        var carried: [(tag: UInt16, bytes: [UInt8])] = []
        if let old, let values = try tail(of: old, in: tiff) {
            plan.truncate = old.offset
            end = old.offset
            carried = values.filter { !position.contains($0.tag) }
        }

        var entries = (old?.entries ?? []).filter { !position.contains($0.tag) }

        // Taken out, and nothing else in the block says anything: the block
        // goes, by taking its pointer out of the first directory. That
        // directory gets shorter, so it is rewritten where it stands.
        if place == nil, !entries.contains(where: { $0.tag != version }), let pointer {
            var rest = root.entries
            rest.remove(at: pointer)
            guard !rest.isEmpty else { return ByteEdit(leavesNothing: true) }
            plan.patches.append(.init(offset: root.offset,
                                      bytes: tiff.bytes(of: rest, next: root.next) + [UInt8](repeating: 0, count: 12)))
            return plan
        }

        if place != nil {
            // A new block says its version. One that was there without it,
            // as ImageIO writes a block, is left without it, as ExifTool
            // leaves it: only the position changes.
            if old == nil {
                insert(Entry(tag: version, type: 1, count: 4, value: [2, 3, 0, 0]), into: &entries)
            }
            insert(Entry(tag: latitudeRef, type: 2, count: 2, value: [0, 0, 0, 0]), into: &entries)
            insert(Entry(tag: latitude, type: 5, count: 3, value: [0, 0, 0, 0]), into: &entries)
            insert(Entry(tag: longitudeRef, type: 2, count: 2, value: [0, 0, 0, 0]), into: &entries)
            insert(Entry(tag: longitude, type: 5, count: 3, value: [0, 0, 0, 0]), into: &entries)
        }

        // Offsets in a TIFF structure are even.
        var append: [UInt8] = end % 2 == 1 ? [0] : []
        var cursor = end + append.count

        // No pointer to a block: the first directory is written again at the
        // end with one in it, and the header is pointed at the copy.
        var movedRoot: Int?
        if pointer == nil {
            var with = root.entries
            let length = 2 + 12 * (with.count + 1) + 4
            let block = try offset(cursor + length)
            insert(Entry(tag: TIFFStructure.gpsPointer, type: 4, count: 1, value: tiff.bytes(block)), into: &with)
            append += tiff.bytes(of: with, next: root.next)
            movedRoot = cursor
            cursor += length
        }

        let blockOffset = cursor
        var values: [UInt8] = []
        var valueCursor = blockOffset + 2 + 12 * entries.count + 4
        if let place {
            func rationals(_ degrees: Double) -> [UInt8] {
                GPSPosition.rationals(degrees).flatMap { tiff.bytes($0.0) + tiff.bytes($0.1) }
            }
            func letter(_ character: Character, for tag: UInt16) {
                guard let index = entries.firstIndex(where: { $0.tag == tag }) else { return }
                entries[index].value = [character.asciiValue ?? 0, 0, 0, 0]
            }
            letter(place.latitude < 0 ? "S" : "N", for: latitudeRef)
            letter(place.longitude < 0 ? "W" : "E", for: longitudeRef)
            try put(rationals(place.latitude), for: latitude, in: &entries, values: &values,
                           cursor: &valueCursor, tiff: tiff)
            try put(rationals(place.longitude), for: longitude, in: &entries, values: &values,
                           cursor: &valueCursor, tiff: tiff)
        }
        for item in carried {
            try put(item.bytes, for: item.tag, in: &entries, values: &values,
                           cursor: &valueCursor, tiff: tiff)
        }
        _ = try offset(valueCursor)

        plan.append = append + tiff.bytes(of: entries, next: 0) + values
        if let movedRoot {
            plan.patches.append(.init(offset: 4, bytes: tiff.bytes(try offset(movedRoot))))
        } else if let pointer, tiff.u32(root.entries[pointer].value, 0) != UInt32(blockOffset) {
            plan.patches.append(.init(offset: root.valueOffset(of: pointer),
                                      bytes: tiff.bytes(try offset(blockOffset))))
        }
        return plan
    }

    /// **The smallest structure a position can be written into**: a header
    /// and a first directory that holds one thing, a pointer to a block
    /// just past its own end, where `plan` then writes one. For a file that
    /// has no EXIF at all.
    ///
    /// Big-endian, which is what ExifTool writes when it starts EXIF afresh.
    static func seed() -> [UInt8] {
        [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,
         0x00, 0x01,
         0x88, 0x25, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1A,
         0x00, 0x00, 0x00, 0x00]
    }

    /// **A structure that states nothing**: the seed, with a block that
    /// holds only its version. For a container that cannot drop its EXIF
    /// when the position was all the EXIF said.
    static func empty() -> [UInt8] {
        seed() + [0x00, 0x01,
                  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x02, 0x03, 0x00, 0x00,
                  0x00, 0x00, 0x00, 0x00]
    }

    /// Puts a value after the block's directory and points its entry at it.
    private static func put(_ bytes: [UInt8], for tag: UInt16, in entries: inout [Entry],
                              values: inout [UInt8], cursor: inout Int, tiff: TIFFStructure) throws {
        guard let index = entries.firstIndex(where: { $0.tag == tag }) else { return }
        if cursor % 2 == 1 {
            values.append(0)
            cursor += 1
        }
        entries[index].value = tiff.bytes(try offset(cursor))
        values += bytes
        cursor += bytes.count
    }

    /// An offset as the structure holds one, which is 32 bits.
    private static func offset(_ value: Int) throws -> UInt32 {
        guard let offset = UInt32(exactly: value) else {
            throw ExifWriterError.unsupported("a structure that would pass 4 GB")
        }
        return offset
    }

    /// Entries stay in the order they were found in, and a new one goes
    /// where its tag belongs, which is ascending.
    private static func insert(_ entry: Entry, into entries: inout [Entry]) {
        entries.insert(entry, at: entries.firstIndex { $0.tag > entry.tag } ?? entries.endIndex)
    }

    private static func isPointer(_ entry: Entry) -> Bool {
        entry.tag == TIFFStructure.gpsPointer && (entry.type == 4 || entry.type == 13) && entry.count == 1
    }

    /// The block the first directory points at, or nil where there is no
    /// pointer or it leads nowhere a directory can be read.
    private static func block(in tiff: TIFFStructure, under root: Directory) -> Directory? {
        guard let entry = root.entries.first(where: isPointer) else { return nil }
        let at = Int(tiff.u32(entry.value, 0))
        guard at != root.offset else { return nil }
        return try? tiff.directory(at: at)
    }

    /// **The block, where it is the last thing in the store**, and nil
    /// where there is none or something follows it.
    ///
    /// For a write that has something else to put at the end
    /// (`TextTags`). It moves this block along and writes before it, so
    /// the block is still last and the next position still costs nothing.
    static func trailing(in tiff: TIFFStructure, under root: TIFFStructure.Directory) throws
        -> TIFFStructure.Directory? {
        guard let found = block(in: tiff, under: root), try tail(of: found, in: tiff) != nil else { return nil }
        return found
    }

    /// The block's directory, wherever it lies.
    static func directory(in tiff: TIFFStructure, under root: TIFFStructure.Directory) -> TIFFStructure.Directory? {
        block(in: tiff, under: root)
    }

    /// **Whether the block is the last thing in the store**: its directory,
    /// then its values end to end, then nothing. Gives the values that lie
    /// in that stretch, which a write that cuts the block off has to carry
    /// into the new one. Nil where anything else could lie in the stretch.
    private static func tail(of block: Directory, in tiff: TIFFStructure) throws
        -> [(tag: UInt16, bytes: [UInt8])]? {
        let directoryEnd = block.offset + block.length
        var runs: [(offset: Int, entry: Entry)] = []
        for entry in block.entries {
            // A type nobody knows the size of: where its value lies cannot
            // be told, so nothing is cut.
            guard entry.size != nil else { return nil }
            guard entry.isOutOfLine else { continue }
            let at = Int(tiff.u32(entry.value, 0))
            // A value before the block stays where it is.
            if at < block.offset { continue }
            guard at >= directoryEnd else { return nil }
            runs.append((at, entry))
        }
        var cursor = directoryEnd
        var values: [(tag: UInt16, bytes: [UInt8])] = []
        for run in runs.sorted(by: { $0.offset < $1.offset }) {
            guard run.offset == cursor || (cursor % 2 == 1 && run.offset == cursor + 1),
                  let bytes = try tiff.value(of: run.entry) else { return nil }
            values.append((run.entry.tag, bytes))
            cursor = run.offset + bytes.count
        }
        let count = tiff.store.count
        guard cursor == count || (cursor % 2 == 1 && cursor + 1 == count) else { return nil }
        return values
    }
}
