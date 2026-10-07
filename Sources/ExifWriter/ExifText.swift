import Foundation

/// **A tag of a file's EXIF that this library will write or take out.**
///
/// A closed list, and not any tag a caller can name by number. The same
/// directories hold the tags that say where the picture's data is and how
/// it is laid out, and a caller that could take any tag out could take
/// those. Every tag here describes the picture and none of them is needed
/// to read it.
public struct ExifTag: Hashable, Sendable, CustomStringConvertible {
    /// Which of the file's directories a tag is kept in.
    public enum Directory: Hashable, Sendable {
        /// The first directory, which describes the picture and what made
        /// it.
        case image
        /// The EXIF directory the first one points at: when the picture
        /// was made, and through what.
        case exif
    }

    public let directory: Directory
    /// The tag's number, as TIFF and EXIF assign it.
    public let number: UInt16
    /// The tag holds text. One that does not can be taken out and not set.
    public let holdsText: Bool
    public let description: String

    private init(_ directory: Directory, _ number: UInt16, _ name: String, text: Bool = true) {
        self.directory = directory
        self.number = number
        holdsText = text
        description = name
    }

    public static let imageDescription = ExifTag(.image, 0x010E, "ImageDescription")
    public static let make = ExifTag(.image, 0x010F, "Make")
    public static let model = ExifTag(.image, 0x0110, "Model")
    public static let software = ExifTag(.image, 0x0131, "Software")
    /// When the file was last changed, `YYYY:MM:DD HH:MM:SS`.
    public static let dateTime = ExifTag(.image, 0x0132, "DateTime")
    public static let artist = ExifTag(.image, 0x013B, "Artist")
    public static let copyright = ExifTag(.image, 0x8298, "Copyright")

    /// When the picture was made, `YYYY:MM:DD HH:MM:SS`.
    public static let dateTimeOriginal = ExifTag(.exif, 0x9003, "DateTimeOriginal")
    /// When it was turned into a file, in the same form.
    public static let dateTimeDigitized = ExifTag(.exif, 0x9004, "DateTimeDigitized")
    /// The offset from UTC of `DateTime`, `+HH:MM`.
    public static let offsetTime = ExifTag(.exif, 0x9010, "OffsetTime")
    public static let offsetTimeOriginal = ExifTag(.exif, 0x9011, "OffsetTimeOriginal")
    public static let offsetTimeDigitized = ExifTag(.exif, 0x9012, "OffsetTimeDigitized")
    /// The fraction of a second that goes with `DateTime`, as digits.
    public static let subSecTime = ExifTag(.exif, 0x9290, "SubSecTime")
    public static let subSecTimeOriginal = ExifTag(.exif, 0x9291, "SubSecTimeOriginal")
    public static let subSecTimeDigitized = ExifTag(.exif, 0x9292, "SubSecTimeDigitized")
    public static let cameraOwnerName = ExifTag(.exif, 0xA430, "CameraOwnerName")
    public static let bodySerialNumber = ExifTag(.exif, 0xA431, "BodySerialNumber")
    /// The lens's focal lengths and apertures, as four fractions. Not text:
    /// it can be taken out, for a file whose lens has been named afresh,
    /// and not set.
    public static let lensSpecification = ExifTag(.exif, 0xA432, "LensSpecification", text: false)
    public static let lensMake = ExifTag(.exif, 0xA433, "LensMake")
    public static let lensModel = ExifTag(.exif, 0xA434, "LensModel")
    public static let lensSerialNumber = ExifTag(.exif, 0xA435, "LensSerialNumber")
}

/// **Reads and writes the text a photograph's EXIF states, without touching
/// the picture**: what made it, through what lens, and when. No decode and
/// no re-encode.
///
/// ## Why
///
/// Apple's `CGImageDestinationCopyImageSource` rewrites a file's metadata
/// without re-encoding it, and in a TIFF it does not write what it was
/// handed. Measured on macOS 27.0.1: a `Model`, a `LensModel` or a
/// `DateTimeDigitized` the file already states is left as it was, an
/// `OffsetTimeOriginal` is not written and one that was there is removed,
/// and a `Make` asked to be taken out stays. The call returns true. This is
/// for setting those right afterwards.
///
/// ## Only a TIFF, and only its EXIF
///
/// **A PNG and a HEIC are refused.** Their EXIF is the same structure
/// inside a chunk or an item, and this does not write it there yet.
///
/// **The XMP packet is not read and not changed.** A packet can state the
/// same thing a second time, as `tiff:Model` or `exif:DateTimeOriginal`.
/// For a position this library keeps the two in step (`ExifGPS`). For text
/// it writes the EXIF alone, so a caller whose file has a packet keeps the
/// packet in step by whatever wrote it.
///
/// ## What moves
///
/// Nothing that is there, as with a position. A value no longer than the
/// one it replaces is written where that one lies. A longer one, or one for
/// a tag the file did not have, goes at the end, and the few bytes that
/// point at it change last. What it replaces stays in the bytes,
/// unreferenced. A GPS block that was the last thing in the file is moved
/// along so it still is, and a later position write still does not grow the
/// file.
public enum ExifText {

    /// The text the file's EXIF holds under `tag`, or nil where it has none
    /// or the tag does not hold text.
    public static func text(of tag: ExifTag, inFileAt url: URL, as container: ImageContainer) throws -> String? {
        try only(container)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try TextTags.text(of: tag, in: FileStore(handle))
    }

    /// The text the bytes' EXIF holds under `tag`.
    public static func text(of tag: ExifTag, in data: Data, as container: ImageContainer) throws -> String? {
        try only(container)
        return try TextTags.text(of: tag, in: ArrayStore(bytes: [UInt8](data)))
    }

    /// **Sets each tag in `text` to its value and takes each tag in
    /// `removing` out.** Returns whether the file was changed: a tag that
    /// already holds the value, or is already absent, changes nothing.
    ///
    /// A tag named in both is set.
    ///
    /// **The file is edited where it stands.** What is new is written at
    /// the end first and the bytes that point at it last. A caller that
    /// needs all or nothing writes into a copy and moves it into place.
    @discardableResult
    public static func set(_ text: [ExifTag: String], removing: Set<ExifTag> = [],
                           inFileAt url: URL, as container: ImageContainer) throws -> Bool {
        try only(container)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let edit = try TextTags.plan(FileStore(handle), setting: text, removing: removing)
        guard !edit.isEmpty else { return false }
        try edit.apply(to: handle)
        return true
    }

    /// The same bytes with each tag in `text` set and each in `removing`
    /// taken out.
    public static func setting(_ text: [ExifTag: String], removing: Set<ExifTag> = [],
                               in data: Data, as container: ImageContainer) throws -> Data {
        try only(container)
        let bytes = [UInt8](data)
        let edit = try TextTags.plan(ArrayStore(bytes: bytes), setting: text, removing: removing)
        return edit.isEmpty ? data : Data(edit.applied(to: bytes))
    }

    private static func only(_ container: ImageContainer) throws {
        switch container {
        case .tiff: return
        case .png: throw ExifWriterError.unsupported("text in a PNG's EXIF")
        case .heic: throw ExifWriterError.unsupported("text in a HEIC's EXIF")
        }
    }
}
