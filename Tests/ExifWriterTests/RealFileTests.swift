#if os(macOS) || os(Linux)
import XCTest
@testable import ExifWriter

/// **The same checks on photographs of your own**, which a repository cannot
/// hold.
///
///     EXIF_WRITER_REAL_FILES=/path/to/a/folder swift test --filter RealFileTests
///
/// The variable names a folder, searched all the way down, or a text file
/// of paths, one to a line. Each file this library writes is copied to the
/// temporary directory and only the copy is touched. Needs ExifTool.
///
/// For each copy: a position is set, moved and taken out, and after each
/// ExifTool must read the position asked for, find the picture's data
/// unchanged by digest, and report every other tag as it was. Where the
/// file's XMP packet stated a position, ExifTool must read the same one
/// there after each write, and where it stated none, none.
final class RealFileTests: XCTestCase {

    private var files: [URL] {
        guard let named = ProcessInfo.processInfo.environment["EXIF_WRITER_REAL_FILES"] else { return [] }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: named, isDirectory: &directory) else { return [] }
        let all: [URL]
        if directory.boolValue {
            let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: named),
                                                      includingPropertiesForKeys: nil)
            all = walk?.compactMap { $0 as? URL } ?? []
        } else {
            let list = (try? String(contentsOfFile: named, encoding: .utf8)) ?? ""
            all = list.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        }
        return all.filter { ImageContainer(pathExtension: $0.pathExtension) != nil }
            .sorted { $0.path < $1.path }
    }

    func testPhotographsOfYourOwn() throws {
        let files = files
        guard !files.isEmpty else { throw XCTSkip("EXIF_WRITER_REAL_FILES names no file this library writes") }
        let first = GPSPosition(latitude: 36.371389, longitude: -121.901944)!
        let second = GPSPosition(latitude: -33.856784, longitude: 151.215297)!
        var summary: [String: Int] = [:]

        for original in files {
            let container = try XCTUnwrap(ImageContainer(pathExtension: original.pathExtension))
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("exif-writer-real-\(UUID().uuidString).\(original.pathExtension)")
            try FileManager.default.copyItem(at: original, to: copy)
            defer { try? FileManager.default.removeItem(at: copy) }
            let name = original.lastPathComponent

            let before = try ExifTool.everything(copy)
            let had = try ExifTool.position(copy)
            let stated = try ExifTool.packetPosition(copy) != nil
            // A file with no EXIF gains some, and with it the tags any EXIF
            // starts with.
            let fresh = before["File:ExifByteOrder"] == nil
            let size = try size(copy)
            XCTAssertNotNil(before["ImageDataHash"], "no digest of the picture: \(name)")
            assertSame(try ExifGPS.position(inFileAt: copy, as: container), had, "reading, \(name)")

            do {
                try ExifGPS.setPosition(first, inFileAt: copy, as: container)
            } catch let error as ExifWriterError {
                summary["refused: \(error)", default: 0] += 1
                XCTAssertEqual(try ExifTool.everything(copy), before, "refused and still changed: \(name)")
                continue
            }
            assertSame(try ExifTool.position(copy), first, "set, \(name)")
            assertSame(try ExifTool.blockPosition(copy), first, "set, in the EXIF, \(name)")
            assertSame(try ExifTool.packetPosition(copy), stated ? first : nil, "set, in the packet, \(name)")
            XCTAssertEqual(ExifTool.differing(ExifTool.withoutPosition(try ExifTool.everything(copy), fresh: fresh),
                                              ExifTool.withoutPosition(before, fresh: fresh)), [], "set, \(name)")
            let placed = try self.size(copy)

            try ExifGPS.setPosition(second, inFileAt: copy, as: container)
            assertSame(try ExifTool.position(copy), second, "moved, \(name)")
            assertSame(try ExifTool.packetPosition(copy), stated ? second : nil, "moved, in the packet, \(name)")
            XCTAssertEqual(ExifTool.differing(ExifTool.withoutPosition(try ExifTool.everything(copy), fresh: fresh),
                                              ExifTool.withoutPosition(before, fresh: fresh)), [], "moved, \(name)")
            XCTAssertEqual(try self.size(copy), placed, "moving it again grew the file: \(name)")

            try ExifGPS.setPosition(nil, inFileAt: copy, as: container)
            XCTAssertNil(try ExifTool.position(copy), "taken out, \(name)")
            XCTAssertNil(try ExifTool.packetPosition(copy), "taken out, in the packet, \(name)")
            XCTAssertEqual(ExifTool.differing(ExifTool.withoutPosition(try ExifTool.everything(copy)),
                                              ExifTool.withoutPosition(before)), [], "taken out, \(name)")

            summary[had == nil ? "had no position" : "had a position", default: 0] += 1
            if stated { summary["stated it in its packet", default: 0] += 1 }
            summary["bytes added by the first write, most"] =
                max(summary["bytes added by the first write, most"] ?? 0, placed - size)
        }
        print("RealFileTests: \(files.count) files.",
              summary.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; "))
    }

    /// **The text tags, on the TIFFs among them.**
    ///
    ///     EXIF_WRITER_REAL_FILES=/path/to/a/folder swift test --filter RealFileTests/testTextOnTIFFsOfYourOwn
    ///
    /// For each copy: a camera, a lens and three times are set and a maker
    /// taken out, then a date and a longer name set, then a position set
    /// and moved. After each, ExifTool must read what was asked for, find
    /// the picture's data unchanged by digest, report every other tag as it
    /// was, and find no fault it did not find before. The second date must
    /// not grow the file, and neither must the second position.
    func testTextOnTIFFsOfYourOwn() throws {
        let files = files.filter { ImageContainer(pathExtension: $0.pathExtension) == .tiff }
        guard !files.isEmpty else { throw XCTSkip("EXIF_WRITER_REAL_FILES names no TIFF") }
        let wanted: [(tag: ExifTag, value: String, key: String)] = [
            (.model, "Nikon FE2", "IFD0:Model"),
            (.dateTimeOriginal, "2019:07:04 22:30:00", "ExifIFD:DateTimeOriginal"),
            (.dateTimeDigitized, "2020:09:13 05:26:40", "ExifIFD:CreateDate"),
            (.offsetTimeOriginal, "+02:00", "ExifIFD:OffsetTimeOriginal"),
            (.lensModel, "Nikkor 50mm f/1.8", "ExifIFD:LensModel"),
        ]
        let removed: [(tag: ExifTag, key: String)] = [(.make, "IFD0:Make"), (.lensMake, "ExifIFD:LensMake")]
        let written = Set(wanted.map(\.key) + removed.map(\.key))
        let notInvented: Set<String> = [
            "Warning                         : Missing required TIFF ExifIFD tag 0xa000 FlashpixVersion",
            "Warning                         : Missing required TIFF ExifIFD tag 0xa001 ColorSpace",
        ]
        func rest(_ tags: [String: String]) -> [String: String] {
            ExifTool.withoutPosition(tags).filter { key, _ in
                !key.hasPrefix("Composite:") && !written.contains(key) && !key.hasSuffix(":ExifOffset")
                    && key != "ExifIFD:ExifVersion"
            }
        }
        func faults(_ url: URL) throws -> Set<String> {
            Set(try ExifTool.faults(url).map {
                $0.replacingOccurrences(of: #" \[x\d+\]$"#, with: "", options: .regularExpression)
            })
        }
        var summary: [String: Int] = [:]

        for original in files {
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("exif-writer-real-\(UUID().uuidString).\(original.pathExtension)")
            try FileManager.default.copyItem(at: original, to: copy)
            defer { try? FileManager.default.removeItem(at: copy) }
            let name = original.lastPathComponent

            let before = try ExifTool.everything(copy)
            let found = try faults(copy)
            let had = try ExifTool.position(copy)
            let size = try size(copy)
            XCTAssertNotNil(before["ImageDataHash"], "no digest of the picture: \(name)")

            do {
                try ExifText.set(Dictionary(uniqueKeysWithValues: wanted.map { ($0.tag, $0.value) }),
                                 removing: Set(removed.map(\.tag)), inFileAt: copy, as: .tiff)
            } catch let error as ExifWriterError {
                summary["refused: \(error)", default: 0] += 1
                XCTAssertEqual(try ExifTool.everything(copy), before, "refused and still changed: \(name)")
                continue
            }
            var read = try ExifTool.everything(copy)
            for (_, value, key) in wanted { XCTAssertEqual(read[key], value, "\(key), \(name)") }
            for (_, key) in removed { XCTAssertNil(read[key], "\(key), \(name)") }
            XCTAssertEqual(ExifTool.differing(rest(read), rest(before)), [], "set, \(name)")
            XCTAssertEqual(read["ImageDataHash"], before["ImageDataHash"], "set, \(name)")
            assertSame(try ExifTool.position(copy), had, "the position, \(name)")
            XCTAssertEqual(try faults(copy).subtracting(found).subtracting(notInvented), [], "set, \(name)")
            let named = try self.size(copy)

            try ExifText.set([.dateTimeOriginal: "1999:12:31 23:59:58", .offsetTimeOriginal: "-07:00"],
                             inFileAt: copy, as: .tiff)
            XCTAssertEqual(try self.size(copy), named, "a second date grew the file: \(name)")
            read = try ExifTool.everything(copy)
            XCTAssertEqual(read["ExifIFD:DateTimeOriginal"], "1999:12:31 23:59:58", name)
            XCTAssertEqual(read["ExifIFD:OffsetTimeOriginal"], "-07:00", name)

            let first = GPSPosition(latitude: 36.371389, longitude: -121.901944)!
            let second = GPSPosition(latitude: -33.856784, longitude: 151.215297)!
            try ExifGPS.setPosition(first, inFileAt: copy, as: .tiff)
            let placed = try self.size(copy)
            try ExifText.set([.model: "A camera with a longer name than the last"], inFileAt: copy, as: .tiff)
            assertSame(try ExifTool.blockPosition(copy), first, "the position after more text, \(name)")
            let renamed = try self.size(copy)
            try ExifGPS.setPosition(second, inFileAt: copy, as: .tiff)
            XCTAssertEqual(try self.size(copy), renamed, "moving it after more text grew the file: \(name)")
            read = try ExifTool.everything(copy)
            XCTAssertEqual(read["IFD0:Model"], "A camera with a longer name than the last", name)
            XCTAssertEqual(read["ImageDataHash"], before["ImageDataHash"], "at the end, \(name)")
            XCTAssertEqual(ExifTool.differing(rest(read).filter { $0.key != "GPS:GPSVersionID" },
                                              rest(before).filter { $0.key != "GPS:GPSVersionID" }), [],
                           "at the end, \(name)")
            XCTAssertEqual(try faults(copy).subtracting(found).subtracting(notInvented)
                .filter { !$0.contains("GPS") }, [], "at the end, \(name)")

            summary["written", default: 0] += 1
            summary["bytes added by the text, most"] = max(summary["bytes added by the text, most"] ?? 0, named - size)
            summary["bytes added by all of it, most"] =
                max(summary["bytes added by all of it, most"] ?? 0, try self.size(copy) - size)
            _ = placed
        }
        print("RealFileTests, text: \(files.count) files.",
              summary.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; "))
    }

    /// **Which of your photographs would be refused, and why.** Every file
    /// is taken as far as working out the write, and nothing is written, so
    /// this reads the originals where they are. It needs no ExifTool and is
    /// quick enough for a whole library:
    ///
    ///     EXIF_WRITER_REAL_FILES=/path/to/a/folder swift test --filter RealFileTests/testWhichWouldBeRefused
    ///
    /// A file this library does not write, such as a HEIC with no EXIF, is
    /// counted. A file read as broken fails the test, because a photograph
    /// other programs open is not broken and this would be misreading it.
    func testWhichWouldBeRefused() throws {
        let files = files
        guard !files.isEmpty else { throw XCTSkip("EXIF_WRITER_REAL_FILES names no file this library writes") }
        let place = GPSPosition(latitude: -33.856784, longitude: 151.215297)!
        var summary: [String: Int] = [:]
        for original in files {
            let container = try XCTUnwrap(ImageContainer(pathExtension: original.pathExtension))
            do {
                switch container {
                case .tiff:
                    let handle = try FileHandle(forReadingFrom: original)
                    defer { try? handle.close() }
                    _ = try TIFFFile.plan(FileStore(handle), setting: place)
                case .png, .heic:
                    _ = try ExifGPS.settingPosition(place, in: Data(contentsOf: original, options: .mappedIfSafe),
                                                    as: container)
                }
                summary["would be written", default: 0] += 1
            } catch let error as ExifWriterError {
                summary["refused: \(error)", default: 0] += 1
                if case .unsupported = error { continue }
                XCTFail("\(original.lastPathComponent): \(error)")
            }
        }
        print("RealFileTests: \(files.count) files.",
              summary.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; "))
    }

    private func size(_ url: URL) throws -> Int {
        try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    private func assertSame(_ found: GPSPosition?, _ wanted: GPSPosition?, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(found == nil, wanted == nil, message, file: file, line: line)
        guard let found, let wanted else { return }
        XCTAssertEqual(found.latitude, wanted.latitude, accuracy: 1e-7, message, file: file, line: line)
        XCTAssertEqual(found.longitude, wanted.longitude, accuracy: 1e-7, message, file: file, line: line)
    }
}
#endif
