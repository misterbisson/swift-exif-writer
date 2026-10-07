import Foundation

/// **The text tags of a TIFF structure**: reading one, and planning the
/// bytes that set some and take others out, in the first directory and in
/// the EXIF directory it points at.
///
/// ## Nothing that is already there moves
///
/// The rule the GPS block is written by (`GPSBlock`), for the same reason:
/// the structure is full of offsets a general reader cannot all find, so it
/// is never rebuilt.
///
/// - **A value that fits where the old one lies is written there.** A date
///   is always the same length, so changing one changes those bytes and
///   nothing else. Not where another tag in the directories read keeps its
///   value in the same bytes: then the two were one value, and writing over
///   it would change both.
/// - **A longer value goes at the end**, and the eight bytes of its entry
///   that say how long it is and where are changed.
/// - **A tag the directory did not have** makes the directory one entry
///   longer, and there is no room for that where it stands. The directory is
///   written again at the end with the entry in it, and the four bytes that
///   point at the directory are changed: the header's for the first
///   directory, the first directory's pointer for the EXIF one.
/// - **A tag taken out** makes the directory shorter, so it is rewritten
///   where it stands and the room left over is zeroed.
///
/// What is replaced stays in the bytes, unreferenced.
///
/// ## A new EXIF directory says its version and nothing else
///
/// `ExifVersion`, 2.32, which is the version that has the offsets from UTC.
/// ExifTool starts a directory with two more tags, `FlashpixVersion` and a
/// `ColorSpace` of uncalibrated, and its validation asks for both. They are
/// left out: the second is a statement about the picture's colour that
/// nobody made, and ImageIO writes neither in a TIFF.
///
/// ## The GPS block stays the last thing
///
/// A block `GPSBlock` wrote is the last thing in the store, which is what
/// lets the next position cut it off and not grow the file. So where this
/// has something to put at the end and the block is there, the block is cut
/// off, what is new is written, and the block is written again after it,
/// with the offsets inside it and the pointer to it moved by the
/// difference.
enum TextTags {
    private typealias Entry = TIFFStructure.Entry
    private typealias Directory = TIFFStructure.Directory

    static let exifPointer: UInt16 = 0x8769
    private static let exifVersion: UInt16 = 0x9000

    // MARK: Reading

    /// The text the structure holds under `tag`, or nil where it has none
    /// or holds something that is not text there.
    static func text(of tag: ExifTag, in store: ByteStore) throws -> String? {
        let tiff = try TIFFStructure(store)
        let root = try tiff.directory(at: tiff.first)
        let directory = tag.directory == .image ? root : exif(in: tiff, under: root)
        guard let entry = directory?.entry(tag.number), entry.type == 2,
              let raw = try tiff.value(of: entry) else { return nil }
        return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: Writing

    /// A value that has to go at the end, and the entry that will point at
    /// it.
    private struct Pending {
        let directory: ExifTag.Directory
        let tag: UInt16
        let bytes: [UInt8]
    }

    /// The bytes that set each tag in `text` and take each tag in
    /// `removing` out. An empty plan means the structure already says all
    /// of it.
    ///
    /// Text is written as UTF-8 with a zero after it, which is what
    /// ExifTool and ImageIO write and read.
    static func plan(_ store: ByteStore, setting text: [ExifTag: String],
                     removing: Set<ExifTag>) throws -> ByteEdit {
        for (tag, value) in text {
            guard tag.holdsText else {
                throw ExifWriterError.unsupported("setting \(tag), which is not text")
            }
            guard !value.utf8.contains(0) else {
                throw ExifWriterError.unsupported("text with a zero byte in it")
            }
        }

        let tiff = try TIFFStructure(store)
        let root = try tiff.directory(at: tiff.first)
        guard !root.entries.contains(where: { $0.tag == exifPointer && !isPointer($0) }) else {
            throw ExifWriterError.malformed("an EXIF pointer that is not an offset")
        }
        let oldExif = exif(in: tiff, under: root)
        let block = GPSBlock.directory(in: tiff, under: root)

        // Where every value these directories keep outside themselves lies,
        // and where the directories lie, so that nothing is written over
        // bytes something else is using.
        var held: [(directory: Int, tag: UInt16?, range: Range<Int>)] = []
        for directory in [root, oldExif, block].compactMap({ $0 }) {
            held.append((directory.offset, nil, directory.offset..<directory.offset + directory.length))
            for entry in directory.entries where entry.isOutOfLine {
                guard let size = entry.size else { continue }
                let at = Int(tiff.u32(entry.value, 0))
                held.append((directory.offset, entry.tag, at..<at + size))
            }
        }
        func usedByAnother(_ range: Range<Int>, than directory: Directory, _ tag: UInt16) -> Bool {
            held.contains { $0.range.overlaps(range) && !($0.directory == directory.offset && $0.tag == tag) }
        }

        var plan = ByteEdit()
        var pending: [Pending] = []

        /// A directory's entries as the change leaves them. A value that
        /// goes at the end is noted in `pending` and its entry's offset
        /// filled in once it is known where the end is.
        func changed(_ old: Directory?, _ which: ExifTag.Directory) throws -> [Entry] {
            var entries = old?.entries ?? []
            for tag in removing where tag.directory == which && text[tag] == nil {
                entries.removeAll { $0.tag == tag.number }
            }
            for (tag, value) in text.sorted(by: { $0.key.number < $1.key.number }) where tag.directory == which {
                let bytes = Array(value.utf8) + [0]
                guard let count = UInt32(exactly: bytes.count) else {
                    throw ExifWriterError.unsupported("text that would pass 4 GB")
                }
                var entry = Entry(tag: tag.number, type: 2, count: count, value: [0, 0, 0, 0])
                let inline = bytes + [UInt8](repeating: 0, count: max(0, 4 - bytes.count))

                guard let index = entries.firstIndex(where: { $0.tag == tag.number }) else {
                    if bytes.count <= 4 {
                        entry.value = inline
                    } else {
                        pending.append(Pending(directory: which, tag: tag.number, bytes: bytes))
                    }
                    entries.insert(entry, at: entries.firstIndex { $0.tag > entry.tag } ?? entries.endIndex)
                    continue
                }

                let was = entries[index]
                let wasText = was.type == 2 ? try tiff.value(of: was) : nil
                if wasText == bytes { continue }
                if bytes.count <= 4 {
                    entry.value = inline
                } else if let old, wasText != nil, was.isOutOfLine, let size = was.size, bytes.count <= size,
                          case let at = Int(tiff.u32(was.value, 0)),
                          !usedByAnother(at..<at + size, than: old, was.tag) {
                    plan.patches.append(.init(offset: at,
                                              bytes: bytes + [UInt8](repeating: 0, count: size - bytes.count)))
                    entry.value = was.value
                } else {
                    pending.append(Pending(directory: which, tag: tag.number, bytes: bytes))
                }
                entries[index] = entry
            }
            return entries
        }

        var image = try changed(root, .image)
        var exifEntries = try changed(oldExif, .exif)
        // A new EXIF directory says its version, as a new GPS block does,
        // and nothing else it was not asked to say.
        if oldExif == nil, !exifEntries.isEmpty, !exifEntries.contains(where: { $0.tag == exifVersion }) {
            exifEntries.insert(Entry(tag: exifVersion, type: 7, count: 4, value: Array("0232".utf8)), at: 0)
        }
        guard !image.isEmpty else {
            throw ExifWriterError.malformed("a TIFF whose first directory would hold nothing")
        }

        // A directory with more entries than it had cannot stay where it is.
        let exifAtEnd = oldExif.map { exifEntries.count > $0.entries.count } ?? !exifEntries.isEmpty
        if exifAtEnd, !image.contains(where: isPointer) {
            let pointer = Entry(tag: exifPointer, type: 4, count: 1, value: [0, 0, 0, 0])
            image.insert(pointer, at: image.firstIndex { $0.tag > exifPointer } ?? image.endIndex)
        }
        let rootAtEnd = image.count > root.entries.count

        // What is new goes at the end, or where a trailing GPS block began,
        // with the block written again after it.
        var base = store.count
        var carried: Directory?
        if !pending.isEmpty || exifAtEnd || rootAtEnd, let trailing = try GPSBlock.trailing(in: tiff, under: root) {
            base = trailing.offset
            carried = trailing
            plan.truncate = base
        }
        var append: [UInt8] = []
        /// Where the next thing appended will lie. Offsets in a TIFF
        /// structure are even.
        func end() -> Int {
            if (base + append.count) % 2 == 1 { append.append(0) }
            return base + append.count
        }
        func point(_ tag: UInt16, in entries: inout [Entry], at offset: Int) throws {
            guard let index = entries.firstIndex(where: { $0.tag == tag }) else { return }
            entries[index].value = tiff.bytes(try Self.offset(offset))
        }

        for value in pending {
            let at = end()
            append += value.bytes
            switch value.directory {
            case .image: try point(value.tag, in: &image, at: at)
            case .exif: try point(value.tag, in: &exifEntries, at: at)
            }
        }

        if exifAtEnd {
            let at = end()
            append += tiff.bytes(of: exifEntries, next: oldExif?.next ?? 0)
            try point(exifPointer, in: &image, at: at)
        } else if let oldExif {
            plan.patches += try differing(oldExif, from: exifEntries, in: tiff)
        }

        // The first directory's place is kept before the block's is known,
        // and its bytes written after, because it points at the block.
        var rootAt: Int?
        if rootAtEnd {
            let at = end()
            rootAt = at
            append += [UInt8](repeating: 0, count: 2 + 12 * image.count + 4)
        }

        if let carried {
            let at = end()
            let difference = at - carried.offset
            var bytes = try store.read(carried.offset, store.count - carried.offset)
            for (index, entry) in carried.entries.enumerated() where entry.isOutOfLine {
                let was = Int(tiff.u32(entry.value, 0))
                // A value that lay before the block has not moved.
                guard was >= carried.offset else { continue }
                bytes.replaceSubrange(2 + 12 * index + 8..<2 + 12 * index + 12,
                                      with: tiff.bytes(try Self.offset(was + difference)))
            }
            append += bytes
            try point(TIFFStructure.gpsPointer, in: &image, at: at)
        }

        if let rootAt {
            let written = tiff.bytes(of: image, next: root.next)
            append.replaceSubrange(rootAt - base..<rootAt - base + written.count, with: written)
            // The header last: until it changes, the old directory stands.
            plan.patches.append(.init(offset: 4, bytes: tiff.bytes(try Self.offset(rootAt))))
        } else {
            plan.patches += try differing(root, from: image, in: tiff)
        }

        _ = try Self.offset(base + append.count)
        plan.append = append
        return plan
    }

    /// **The bytes of a directory that differ once it holds `entries`**,
    /// which are no more than it held. Only the stretches that differ, so
    /// an entry that did not change is not written.
    private static func differing(_ old: Directory, from entries: [Entry],
                                  in tiff: TIFFStructure) throws -> [ByteEdit.Patch] {
        let was = try tiff.store.read(old.offset, old.length)
        let now = tiff.bytes(of: entries, next: old.next)
            + [UInt8](repeating: 0, count: 12 * (old.entries.count - entries.count))
        var patches: [ByteEdit.Patch] = []
        var start: Int?
        for index in 0...now.count {
            let differs = index < now.count && now[index] != was[index]
            if differs, start == nil { start = index }
            if !differs, let from = start {
                patches.append(.init(offset: old.offset + from, bytes: Array(now[from..<index])))
                start = nil
            }
        }
        return patches
    }

    private static func isPointer(_ entry: Entry) -> Bool {
        entry.tag == exifPointer && (entry.type == 4 || entry.type == 13) && entry.count == 1
    }

    /// The EXIF directory the first one points at, or nil where there is no
    /// pointer or it leads nowhere a directory can be read.
    private static func exif(in tiff: TIFFStructure, under root: Directory) -> Directory? {
        guard let entry = root.entries.first(where: isPointer) else { return nil }
        let at = Int(tiff.u32(entry.value, 0))
        guard at != root.offset else { return nil }
        return try? tiff.directory(at: at)
    }

    /// An offset as the structure holds one, which is 32 bits.
    private static func offset(_ value: Int) throws -> UInt32 {
        guard let offset = UInt32(exactly: value) else {
            throw ExifWriterError.unsupported("a structure that would pass 4 GB")
        }
        return offset
    }
}
