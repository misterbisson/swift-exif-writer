import Foundation

/// **A TIFF file**: the structure itself, whose GPS block is the position,
/// and the XMP packet its first directory may point at, which can state the
/// position a second time.
///
/// ## The packet is changed where it lies when it fits
///
/// A packet is made with white space at its end for this. Where the new
/// position is no longer than the old, or the padding covers the
/// difference, the few bytes that differ are overwritten and the packet
/// keeps its length and its place.
///
/// Where it does not fit, the packet is written again at the end of the
/// file with room for any position, and the eight bytes in the first
/// directory that say where it is and how long are changed. The old packet
/// stays in the bytes, unreferenced. That happens once: the new packet has
/// the room, so the next write fits.
///
/// ## The packet first, then the block
///
/// So that the block stays the last thing in the file, which is what lets
/// the next write cut it off and not grow the file (`GPSBlock`). A block
/// that was last before the packet was moved there is left where it was,
/// unreferenced, and a new one written after the packet: a few hundred
/// bytes, once.
enum TIFFFile {

    /// The position the file states: its GPS block's, and where it has
    /// none there, its XMP packet's.
    static func position(in store: ByteStore) throws -> GPSPosition? {
        if let stated = try GPSBlock.position(in: store) { return stated }
        guard let packet = try packet(in: store) else { return nil }
        return try XMPPacket.position(in: packet.bytes)
    }

    /// The bytes that set the position, or with nil take it out, in the
    /// block and in the packet.
    static func plan(_ store: ByteStore, setting position: GPSPosition?) throws -> ByteEdit {
        let described = try planPacket(store, setting: position)
        let placed = try GPSBlock.plan(described.isEmpty ? store : EditedStore(base: store, edit: described),
                                       setting: position)
        guard !placed.leavesNothing else { return placed }
        return described.then(placed, over: store.count)
    }

    private struct Packet {
        let tiff: TIFFStructure
        let root: TIFFStructure.Directory
        /// Which of the first directory's entries points at it.
        let index: Int
        let offset: Int
        let bytes: [UInt8]
    }

    private static func packet(in store: ByteStore) throws -> Packet? {
        let tiff = try TIFFStructure(store)
        let root = try tiff.directory(at: tiff.first)
        guard let index = root.index(of: TIFFStructure.xmpPacket) else { return nil }
        let entry = root.entries[index]
        // Bytes, or bytes of no stated kind, which is how the two writers
        // of packets hold one.
        guard entry.type == 1 || entry.type == 7, entry.isOutOfLine,
              let bytes = try tiff.value(of: entry) else { return nil }
        return Packet(tiff: tiff, root: root, index: index, offset: Int(tiff.u32(entry.value, 0)), bytes: bytes)
    }

    private static func planPacket(_ store: ByteStore, setting position: GPSPosition?) throws -> ByteEdit {
        guard let old = try packet(in: store),
              let new = try XMPPacket.setting(position, in: old.bytes), new != old.bytes else { return ByteEdit() }

        if let fitted = XMPPacket.fitted(new, to: old.bytes.count) {
            // Only the stretch that differs is written.
            guard let first = fitted.indices.first(where: { fitted[$0] != old.bytes[$0] }),
                  let last = fitted.indices.last(where: { fitted[$0] != old.bytes[$0] }) else { return ByteEdit() }
            return ByteEdit(patches: [.init(offset: old.offset + first, bytes: Array(fitted[first...last]))])
        }

        let roomy = XMPPacket.fitted(new, to: new.count + (try XMPPacket.slack(in: new))) ?? new
        // Offsets in a TIFF structure are even.
        let pad: [UInt8] = store.count % 2 == 1 ? [0] : []
        guard let at = UInt32(exactly: store.count + pad.count),
              let length = UInt32(exactly: roomy.count),
              UInt32(exactly: store.count + pad.count + roomy.count) != nil else {
            throw ExifWriterError.unsupported("a structure that would pass 4 GB")
        }
        return ByteEdit(append: pad + roomy,
                        patches: [.init(offset: old.root.countOffset(of: old.index),
                                        bytes: old.tiff.bytes(length) + old.tiff.bytes(at))])
    }
}
