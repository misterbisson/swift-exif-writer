import Foundation

/// The kind of file a position is read from or written into.
///
/// Said by the caller and not guessed from the bytes. Most cameras' raw
/// files are TIFF structures too, and nothing in the first bytes tells one
/// from a TIFF, so a guess would write into a raw file.
public enum ImageContainer: Sendable, CaseIterable {
    case tiff
    case png
    case heic

    /// From a file name's extension, or nil for one this library does not
    /// write.
    public init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "tif", "tiff": self = .tiff
        case "png": self = .png
        case "heic", "heif": self = .heic
        default: return nil
        }
    }
}

/// **Reads and writes the position a photograph states without touching
/// the picture.** No decode and no re-encode.
///
/// The position is the GPS block of the file's EXIF. A file can state it a
/// second time in its XMP packet, and some state it only there. Setting a
/// position writes the EXIF, and changes the packet's copy where the packet
/// has one, so the two agree. A packet that states none is left as it was,
/// and no packet is made. What follows a PNG's packet in its chunk, which
/// ImageIO can leave there, is cut off on any write.
public enum ExifGPS {

    /// The position the file states, or nil where it states none: the
    /// EXIF's, and where the EXIF has none, the XMP packet's.
    public static func position(inFileAt url: URL, as container: ImageContainer) throws -> GPSPosition? {
        switch container {
        case .tiff:
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try TIFFFile.position(in: FileStore(handle))
        case .png, .heic:
            return try position(in: Data(contentsOf: url), as: container)
        }
    }

    /// **What the file's EXIF states and what its XMP packet states,
    /// apart.** After a write by this library the two agree wherever the
    /// packet states one. In a file somebody else wrote they may not.
    public static func positions(inFileAt url: URL, as container: ImageContainer) throws -> StatedPositions {
        switch container {
        case .tiff:
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try TIFFFile.positions(in: FileStore(handle))
        case .png, .heic:
            return try positions(in: Data(contentsOf: url), as: container)
        }
    }

    /// **Sets the file's position, or with nil takes it out**, in its EXIF
    /// and in its XMP packet where the packet states one. Returns whether
    /// the file was changed: taking a position out of a file that has none
    /// changes nothing, unless it is a PNG with something after its packet
    /// to cut off.
    ///
    /// **A TIFF is edited where it stands.** What is new is written at the
    /// end first and the few bytes that point at it last, so an interrupted
    /// write leaves the picture and the rest of its metadata readable. The
    /// packet's copy is the exception where it fits: those few bytes are
    /// overwritten where they lie. A caller that needs all or nothing
    /// writes into a copy and moves it into place.
    ///
    /// **A PNG or a HEIC is written whole to a new file beside it, which
    /// then takes its place**, because what follows the EXIF has to move
    /// along. The file is read into memory to do it.
    @discardableResult
    public static func setPosition(_ position: GPSPosition?, inFileAt url: URL,
                                   as container: ImageContainer) throws -> Bool {
        switch container {
        case .tiff:
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let edit = try TIFFFile.plan(FileStore(handle), setting: position)
            guard !edit.leavesNothing else { throw onlyAPosition }
            guard !edit.isEmpty else { return false }
            try edit.apply(to: handle)
            return true
        case .png, .heic:
            let before = try Data(contentsOf: url)
            let after = try settingPosition(position, in: before, as: container)
            guard after != before else { return false }
            try after.write(to: url, options: .atomic)
            return true
        }
    }

    /// The position the bytes state, or nil where they state none.
    public static func position(in data: Data, as container: ImageContainer) throws -> GPSPosition? {
        switch container {
        case .tiff: return try TIFFFile.position(in: ArrayStore(bytes: [UInt8](data)))
        case .png: return try PNGFile.position(in: [UInt8](data))
        case .heic: return try HEICFile.position(in: [UInt8](data))
        }
    }

    /// What the bytes' EXIF states and what their XMP packet states,
    /// apart.
    public static func positions(in data: Data, as container: ImageContainer) throws -> StatedPositions {
        switch container {
        case .tiff: return try TIFFFile.positions(in: ArrayStore(bytes: [UInt8](data)))
        case .png: return try PNGFile.positions(in: [UInt8](data))
        case .heic: return try HEICFile.positions(in: [UInt8](data))
        }
    }

    /// The same bytes with the position set, or with nil taken out.
    public static func settingPosition(_ position: GPSPosition?, in data: Data,
                                       as container: ImageContainer) throws -> Data {
        let bytes = [UInt8](data)
        switch container {
        case .tiff:
            let edit = try TIFFFile.plan(ArrayStore(bytes: bytes), setting: position)
            guard !edit.leavesNothing else { throw onlyAPosition }
            return Data(edit.applied(to: bytes))
        case .png:
            return try PNGFile.setting(position, in: bytes).map { Data($0) } ?? data
        case .heic:
            return try HEICFile.setting(position, in: bytes).map { Data($0) } ?? data
        }
    }

    private static let onlyAPosition =
        ExifWriterError.malformed("a TIFF whose first directory holds nothing but a position")
}
