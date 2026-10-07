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
/// unchanged by digest, and report every other tag as it was.
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
            XCTAssertEqual(ExifTool.withoutPosition(try ExifTool.everything(copy)),
                           ExifTool.withoutPosition(before), "set, \(name)")
            let placed = try self.size(copy)

            try ExifGPS.setPosition(second, inFileAt: copy, as: container)
            assertSame(try ExifTool.position(copy), second, "moved, \(name)")
            XCTAssertEqual(ExifTool.withoutPosition(try ExifTool.everything(copy)),
                           ExifTool.withoutPosition(before), "moved, \(name)")
            XCTAssertEqual(try self.size(copy), placed, "moving it again grew the file: \(name)")

            try ExifGPS.setPosition(nil, inFileAt: copy, as: container)
            XCTAssertNil(try ExifTool.position(copy), "taken out, \(name)")
            XCTAssertEqual(ExifTool.withoutPosition(try ExifTool.everything(copy)),
                           ExifTool.withoutPosition(before), "taken out, \(name)")

            summary[had == nil ? "had no position" : "had a position", default: 0] += 1
            summary["bytes added by the first write, most"] =
                max(summary["bytes added by the first write, most"] ?? 0, placed - size)
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
