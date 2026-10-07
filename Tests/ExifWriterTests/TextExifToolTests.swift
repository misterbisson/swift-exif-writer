#if os(macOS) || os(Linux)
import XCTest
@testable import ExifWriter

/// **The text tags checked against ExifTool**, both ways round, on the
/// hand-built TIFFs the position is checked on and on some that state text
/// already.
final class TextExifToolTests: XCTestCase {

    private struct Case {
        let name: String
        let bytes: [UInt8]
    }

    private static let scanned: [UInt16: String] = [0x010F: "EPSON", 0x0110: "EPSON Perfection V600"]
    private static let dated: [UInt16: String] = [
        0x9003: "2001:01:01 01:01:01", 0x9004: "2002:02:02 02:02:02", 0x9011: "+09:00", 0xA434: "Old Lens",
    ]

    /// Every TIFF the position is checked on, and TIFFs that already state
    /// what is about to be set, in both byte orders.
    private var cases: [Case] {
        Sample.all.filter { $0.container == .tiff }.map { Case(name: $0.name, bytes: $0.bytes) } + [
            Case(name: "little, a scanner and a time", bytes: Fixture(text: Self.scanned, exif: Self.dated).bytes()),
            Case(name: "big, a scanner and a time",
                 bytes: Fixture(little: false, text: Self.scanned, exif: Self.dated).bytes()),
            Case(name: "little, a scanner, a time and a block last",
                 bytes: Fixture(block: .camera(latitude: 36.606111, longitude: -118.062778, altitude: 1136.5),
                                blockLast: true, text: Self.scanned, exif: Self.dated).bytes()),
            Case(name: "big, an EXIF directory with one tag", bytes: Fixture(little: false, exif: [0x9003: "2001:01:01 01:01:01"]).bytes()),
        ]
    }

    /// What is set, and the name ExifTool reports each under.
    private let wanted: [(tag: ExifTag, value: String, key: String)] = [
        (.model, "Nikon FE2", "IFD0:Model"),
        (.software, "Anchorframe", "IFD0:Software"),
        (.dateTimeOriginal, "2019:07:04 22:30:00", "ExifIFD:DateTimeOriginal"),
        (.dateTimeDigitized, "2020:09:13 05:26:40", "ExifIFD:CreateDate"),
        (.offsetTimeOriginal, "+02:00", "ExifIFD:OffsetTimeOriginal"),
        (.lensModel, "Pentax 28–70mm ƒ/4", "ExifIFD:LensModel"),
    ]
    private let removed: [(tag: ExifTag, key: String)] = [(.make, "IFD0:Make"), (.lensMake, "ExifIFD:LensMake")]

    private var text: [ExifTag: String] { Dictionary(uniqueKeysWithValues: wanted.map { ($0.tag, $0.value) }) }

    /// Everything ExifTool reports that is not one of the tags written, not
    /// worked out from them, and not the plumbing that points at a
    /// directory or says an EXIF directory's version.
    private func rest(_ tags: [String: String]) -> [String: String] {
        let written = Set(wanted.map(\.key) + removed.map(\.key))
        return tags.filter { key, _ in
            key != "SourceFile" && !["System:", "ExifTool:", "MacOS:", "Composite:"].contains { key.hasPrefix($0) }
                && !written.contains(key) && !key.hasSuffix(":GPSInfo") && !key.hasSuffix(":ExifOffset")
                && key != "ExifIFD:ExifVersion"
        }
    }

    // MARK: - ExifTool reads what this library wrote

    func testExifToolReadsTheTextThisWrote() throws {
        for item in cases {
            let file = try Scratch(item.bytes)
            XCTAssertTrue(try ExifText.set(text, removing: Set(removed.map(\.tag)), inFileAt: file.url, as: .tiff))
            let read = try ExifTool.everything(file.url)
            for (_, value, key) in wanted { XCTAssertEqual(read[key], value, "\(key), \(item.name)") }
            for (_, key) in removed { XCTAssertNil(read[key], "\(key), \(item.name)") }
        }
    }

    /// **Nothing ExifTool reports about the file changes but the tags
    /// written**: every other tag, the position, and a digest of the
    /// picture's data.
    func testNothingButTheTextChanges() throws {
        for item in cases {
            let file = try Scratch(item.bytes)
            let before = try ExifTool.everything(file.url)
            try ExifText.set(text, removing: Set(removed.map(\.tag)), inFileAt: file.url, as: .tiff)
            let after = try ExifTool.everything(file.url)
            XCTAssertEqual(ExifTool.differing(rest(after), rest(before)), [], item.name)
            XCTAssertNotNil(after["ImageDataHash"], "the digest of the picture was compared")
            XCTAssertEqual(after["ImageDataHash"], before["ImageDataHash"], item.name)

            // And taken out again, the file says what it said of everything else.
            try ExifText.set([:], removing: Set(wanted.map(\.tag)), inFileAt: file.url, as: .tiff)
            let cleared = try ExifTool.everything(file.url)
            XCTAssertEqual(ExifTool.differing(rest(cleared), rest(before)), [], "cleared, \(item.name)")
            for (_, _, key) in wanted { XCTAssertNil(cleared[key], "\(key), \(item.name)") }
        }
    }

    /// **ExifTool's validation finds nothing wrong with a file this library
    /// wrote that it does not find wrong with one it wrote itself**, or
    /// with the file before, but for two tags.
    ///
    /// ExifTool starts an EXIF directory with `FlashpixVersion` and a
    /// `ColorSpace` of uncalibrated, and its validation asks for both in
    /// any EXIF directory. This library does not invent either
    /// (`TextTags`), so a directory it started is told it lacks them.
    func testExifToolFindsNoFaultItsOwnWritingLacks() throws {
        let notInvented = [
            "Warning                         : Missing required TIFF ExifIFD tag 0xa000 FlashpixVersion",
            "Warning                         : Missing required TIFF ExifIFD tag 0xa001 ColorSpace",
        ]
        for item in cases {
            let ours = try Scratch(item.bytes)
            let theirs = try Scratch(item.bytes)
            let before = try ExifTool.faults(ours.url)
            try ExifTool.run(["-q", "-overwrite_original"] + wanted.map { "-\($0.key)=\($0.value)" }
                             + removed.map { "-\($0.key)=" } + [theirs.url.path])
            let allowed = Set(before + (try ExifTool.faults(theirs.url)) + notInvented)

            try ExifText.set(text, removing: Set(removed.map(\.tag)), inFileAt: ours.url, as: .tiff)
            XCTAssertEqual(try ExifTool.faults(ours.url).filter { !allowed.contains($0) }, [], "set, \(item.name)")
            try ExifText.set([.model: "A longer name than the one before it", .dateTimeOriginal: "1999:12:31 23:59:58"],
                             inFileAt: ours.url, as: .tiff)
            XCTAssertEqual(try ExifTool.faults(ours.url).filter { !allowed.contains($0) }, [], "changed, \(item.name)")
            try ExifText.set([:], removing: Set(wanted.map(\.tag)), inFileAt: ours.url, as: .tiff)
            XCTAssertEqual(try ExifTool.faults(ours.url).filter { !allowed.contains($0) }, [], "cleared, \(item.name)")
        }
    }

    /// The text and the position, written one after the other in each
    /// order, and both read.
    func testTextAndAPositionTogether() throws {
        let bixby = GPSPosition(latitude: 36.371389, longitude: -121.901944)!
        for item in cases {
            for textFirst in [true, false] {
                let file = try Scratch(item.bytes)
                if textFirst { try ExifText.set(text, inFileAt: file.url, as: .tiff) }
                try ExifGPS.setPosition(bixby, inFileAt: file.url, as: .tiff)
                if !textFirst { try ExifText.set(text, inFileAt: file.url, as: .tiff) }
                let read = try ExifTool.everything(file.url)
                for (_, value, key) in wanted { XCTAssertEqual(read[key], value, "\(key), \(item.name)") }
                let position = try ExifTool.blockPosition(file.url)
                XCTAssertEqual(position?.latitude ?? .nan, bixby.latitude, accuracy: 1e-7, item.name)
                XCTAssertEqual(position?.longitude ?? .nan, bixby.longitude, accuracy: 1e-7, item.name)
                let untouched = try Scratch(item.bytes)
                XCTAssertEqual(read["ImageDataHash"], try ExifTool.everything(untouched.url)["ImageDataHash"], item.name)
            }
        }
    }

    // MARK: - This library reads what ExifTool wrote

    func testThisReadsAndChangesWhatExifToolWrote() throws {
        for item in cases {
            let file = try Scratch(item.bytes)
            try ExifTool.run(["-q", "-overwrite_original"] + wanted.map { "-\($0.key)=\($0.value)" } + [file.url.path])
            for (tag, value, key) in wanted {
                XCTAssertEqual(try ExifText.text(of: tag, inFileAt: file.url, as: .tiff), value, "\(key), \(item.name)")
            }
            XCTAssertFalse(try ExifText.set(text, inFileAt: file.url, as: .tiff), "it already says all of it")

            try ExifText.set([.model: "Leica M6", .offsetTimeOriginal: "-07:00"], removing: [.lensModel],
                             inFileAt: file.url, as: .tiff)
            let read = try ExifTool.everything(file.url)
            XCTAssertEqual(read["IFD0:Model"], "Leica M6", item.name)
            XCTAssertEqual(read["ExifIFD:OffsetTimeOriginal"], "-07:00", item.name)
            XCTAssertNil(read["ExifIFD:LensModel"], item.name)
            XCTAssertEqual(read["ExifIFD:DateTimeOriginal"], "2019:07:04 22:30:00", item.name)
        }
    }
}
#endif
