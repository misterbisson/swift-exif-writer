#if os(macOS) || os(Linux)
import XCTest
@testable import ExifWriter

/// **This library checked against ExifTool**, which has written these
/// formats for twenty years and shares no code with it.
///
/// Each case is asked both ways round: ExifTool reads what this library
/// wrote, and this library reads what ExifTool wrote.
///
/// The tests are skipped where ExifTool is not installed, and fail there
/// when `EXIFTOOL_REQUIRED` is set, as it is in CI, so a run that could not
/// check anything is never counted as one that passed.
final class ExifToolTests: XCTestCase {

    private let bixby = GPSPosition(latitude: 36.371389, longitude: -121.901944)!
    private let sydney = GPSPosition(latitude: -33.856784, longitude: 151.215297)!

    // MARK: - ExifTool reads what this library wrote

    func testExifToolReadsThePositionThisWrote() throws {
        for sample in Sample.all {
            for place in [bixby, sydney] {
                let file = try sample.scratch()
                try ExifGPS.setPosition(place, inFileAt: file.url, as: sample.container)
                let read = try ExifTool.position(file.url)
                XCTAssertEqual(read?.latitude ?? .nan, place.latitude, accuracy: 1e-7, sample.name)
                XCTAssertEqual(read?.longitude ?? .nan, place.longitude, accuracy: 1e-7, sample.name)
            }
        }
    }

    /// **Nothing ExifTool reports about the file changes but its position**:
    /// every other tag, where the picture's data is, and a digest of that
    /// data.
    func testNothingButThePositionChanges() throws {
        for sample in Sample.all {
            let file = try sample.scratch()
            let before = try ExifTool.everything(file.url)
            let fresh = before["File:ExifByteOrder"] == nil
            try ExifGPS.setPosition(bixby, inFileAt: file.url, as: sample.container)
            let placed = try ExifTool.everything(file.url)
            XCTAssertEqual(ExifTool.withoutPosition(placed, fresh: fresh),
                           ExifTool.withoutPosition(before, fresh: fresh), sample.name)
            XCTAssertNotNil(placed["ImageDataHash"], "the digest of the picture was compared")

            try ExifGPS.setPosition(nil, inFileAt: file.url, as: sample.container)
            let cleared = try ExifTool.everything(file.url)
            XCTAssertEqual(ExifTool.withoutPosition(cleared), ExifTool.withoutPosition(before), sample.name)
            XCTAssertNil(try ExifTool.position(file.url), sample.name)
        }
    }

    /// **ExifTool's validation finds nothing wrong with a file this library
    /// wrote that it does not find wrong with one it wrote itself.**
    ///
    /// Its own file is the measure, and not the file before, because its
    /// validation asks more of a GPS block than of a file with none: it
    /// warns that a block it has just written lacks `GPSProcessingMethod`.
    /// Once the position is taken out the file may have no fault it did not
    /// start with. It may have fewer: a PNG's EXIF found after the picture
    /// is moved before it, which is one warning gone.
    func testExifToolFindsNoFaultItsOwnWritingLacks() throws {
        for sample in Sample.all {
            let ours = try sample.scratch()
            let theirs = try sample.scratch()
            let before = try ExifTool.faults(ours.url)
            try ExifTool.setPosition(bixby, theirs.url)
            let reference = try ExifTool.faults(theirs.url)

            try ExifGPS.setPosition(sydney, inFileAt: ours.url, as: sample.container)
            XCTAssertEqual(try ExifTool.faults(ours.url), reference, "placed, \(sample.name)")
            try ExifGPS.setPosition(bixby, inFileAt: ours.url, as: sample.container)
            XCTAssertEqual(try ExifTool.faults(ours.url), reference, "moved, \(sample.name)")
            try ExifGPS.setPosition(nil, inFileAt: ours.url, as: sample.container)
            let cleared = try ExifTool.faults(ours.url)
            XCTAssertEqual(cleared.filter { !before.contains($0) }, [], "cleared, \(sample.name)")
        }
    }

    // MARK: - This library reads what ExifTool wrote

    func testThisReadsThePositionExifToolWrote() throws {
        for sample in Sample.all {
            for place in [bixby, sydney] {
                let file = try sample.scratch()
                try ExifTool.setPosition(place, file.url)
                let read = try ExifGPS.position(inFileAt: file.url, as: sample.container)
                XCTAssertEqual(read?.latitude ?? .nan, place.latitude, accuracy: 1e-7, sample.name)
                XCTAssertEqual(read?.longitude ?? .nan, place.longitude, accuracy: 1e-7, sample.name)
            }
        }
    }

    /// **The two writers leave files ExifTool describes the same way.**
    func testBothWritersLeaveTheSameTags() throws {
        for sample in Sample.all {
            let ours = try sample.scratch()
            let theirs = try sample.scratch()
            let fresh = try ExifTool.everything(ours.url)["File:ExifByteOrder"] == nil
            try ExifGPS.setPosition(bixby, inFileAt: ours.url, as: sample.container)
            try ExifTool.setPosition(bixby, theirs.url)
            XCTAssertEqual(ExifTool.comparable(try ExifTool.everything(ours.url), fresh: fresh),
                           ExifTool.comparable(try ExifTool.everything(theirs.url), fresh: fresh), sample.name)
        }
    }

    /// This library moves and clears a position ExifTool wrote, and ExifTool
    /// agrees with the result.
    func testThisEditsWhatExifToolWrote() throws {
        for sample in Sample.all {
            let file = try sample.scratch()
            try ExifTool.setPosition(sydney, file.url)
            let before = try ExifTool.everything(file.url)
            try ExifGPS.setPosition(bixby, inFileAt: file.url, as: sample.container)
            let read = try ExifTool.position(file.url)
            XCTAssertEqual(read?.latitude ?? .nan, bixby.latitude, accuracy: 1e-7, sample.name)
            XCTAssertEqual(ExifTool.withoutPosition(try ExifTool.everything(file.url)),
                           ExifTool.withoutPosition(before), sample.name)
            try ExifGPS.setPosition(nil, inFileAt: file.url, as: sample.container)
            XCTAssertNil(try ExifTool.position(file.url), sample.name)
        }
    }
}

/// One hand-built file the two writers are both put to.
struct Sample {
    let name: String
    let container: ImageContainer
    let bytes: [UInt8]

    func scratch() throws -> Scratch {
        try Scratch(bytes, extension: container == .tiff ? "tif" : "png")
    }

    private static let camera = Fixture.Block.camera(latitude: 36.606111, longitude: -118.062778,
                                                     altitude: 1136.5)

    static let all: [Sample] = [
        Sample(name: "TIFF, little, no block", container: .tiff, bytes: Fixture().bytes()),
        Sample(name: "TIFF, big, no block", container: .tiff, bytes: Fixture(little: false).bytes()),
        Sample(name: "TIFF, little, camera", container: .tiff, bytes: Fixture(block: camera).bytes()),
        Sample(name: "TIFF, big, camera", container: .tiff,
               bytes: Fixture(little: false, block: camera).bytes()),
        Sample(name: "TIFF, little, block last", container: .tiff,
               bytes: Fixture(block: .camera(latitude: 1, longitude: 2, altitude: 3), blockLast: true).bytes()),
        Sample(name: "TIFF, little, altitude only", container: .tiff,
               bytes: Fixture(block: .altitudeOnly(250)).bytes()),
        Sample(name: "PNG, no EXIF", container: .png, bytes: PNGFixture().bytes()),
        Sample(name: "PNG, little EXIF with a camera's block", container: .png,
               bytes: PNGFixture(exif: .holding(Fixture(block: camera).bytes())).bytes()),
        Sample(name: "PNG, big EXIF with a camera's block", container: .png,
               bytes: PNGFixture(exif: .holding(Fixture(little: false, block: camera).bytes())).bytes()),
        Sample(name: "PNG, EXIF after the picture", container: .png,
               bytes: PNGFixture(exif: .holding(Fixture(block: .altitudeOnly(250)).bytes()),
                                 exifLast: true).bytes()),
    ]
}

/// A file in the temporary directory that goes when the test does.
final class Scratch {
    let url: URL

    init(_ bytes: [UInt8], extension ext: String = "tif") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exif-writer-\(UUID().uuidString).\(ext)")
        try Data(bytes).write(to: url)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// ExifTool, run as a program.
enum ExifTool {
    static let path: String? = {
        let named = ProcessInfo.processInfo.environment["EXIFTOOL"].map { [$0] } ?? []
        let searched = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { "\($0)/exiftool" }
        return (named + searched + ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool", "/usr/bin/exiftool"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// The path, or a skip. A failure where the run was told ExifTool must
    /// be there.
    static func required() throws -> String {
        if let path { return path }
        if ProcessInfo.processInfo.environment["EXIFTOOL_REQUIRED"] != nil {
            XCTFail("EXIFTOOL_REQUIRED is set and exiftool was not found")
        }
        throw XCTSkip("exiftool is not installed")
    }

    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try required())
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let said = out.fileHandleForReading.readDataToEndOfFile()
        let complained = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failed(arguments: arguments, said: String(decoding: complained, as: UTF8.self))
        }
        return String(decoding: said, as: UTF8.self)
    }

    struct Failed: Error {
        let arguments: [String]
        let said: String
    }

    /// Every tag ExifTool reports, by group and name, as numbers where they
    /// are numbers, with a digest of the picture's data.
    static func everything(_ url: URL) throws -> [String: String] {
        let json = try run(["-j", "-G1", "-a", "-u", "-n", "-api", "RequestAll=3", "-ImageDataHash",
                            "-all", url.path])
        let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        var out: [String: String] = [:]
        for (key, value) in rows?.first ?? [:] { out[key] = "\(value)" }
        if let digest = out.first(where: { $0.key.hasSuffix("ImageDataHash") }) {
            out["ImageDataHash"] = digest.value
        }
        return out
    }

    /// The file's own tags and nothing about where it sits on disk.
    private static func ofTheFile(_ tags: [String: String]) -> [String: String] {
        tags.filter { key, _ in
            key != "SourceFile" && !["System:", "ExifTool:", "MacOS:"].contains { key.hasPrefix($0) }
        }
    }

    private static let position: Set<String> = [
        "GPS:GPSLatitude", "GPS:GPSLatitudeRef", "GPS:GPSLongitude", "GPS:GPSLongitudeRef",
        "Composite:GPSLatitude", "Composite:GPSLongitude", "Composite:GPSPosition",
    ]

    /// What a file gains when it had no EXIF at all and is given some: the
    /// byte order of the new EXIF, and the tags ExifTool puts in any EXIF it
    /// starts. Those are defaults and not facts about the file: how a JPEG's
    /// colour samples sit, and, from the ExifTool 12 that Ubuntu packages, a
    /// resolution of 72 to the inch. This library writes none of them.
    private static let startingExif: Set<String> = [
        "File:ExifByteOrder", "IFD0:YCbCrPositioning",
        "IFD0:XResolution", "IFD0:YResolution", "IFD0:ResolutionUnit",
    ]

    /// Everything but the position, the version a new block states, and the
    /// pointer to the block, which is the position's own plumbing. `fresh`
    /// where the file had no EXIF before.
    static func withoutPosition(_ tags: [String: String], fresh: Bool = false) -> [String: String] {
        ofTheFile(tags).filter {
            !position.contains($0.key) && $0.key != "GPS:GPSVersionID" && !$0.key.hasSuffix(":GPSInfo")
                && !(fresh && startingExif.contains($0.key))
        }
    }

    /// For comparing two writers' files: positions rounded to what both
    /// keep, and the plumbing left out. Where the picture's data sits is
    /// plumbing here, because ExifTool lays the file out afresh.
    static func comparable(_ tags: [String: String], fresh: Bool = false) -> [String: String] {
        var out = withoutPosition(tags, fresh: fresh).filter { !$0.key.hasSuffix(":StripOffsets") }
        for key in ["Composite:GPSLatitude", "Composite:GPSLongitude"] {
            out[key] = tags[key].flatMap(Double.init).map { String(format: "%.6f", $0) }
        }
        out["GPS:GPSVersionID"] = tags["GPS:GPSVersionID"]
        return out
    }

    static func position(_ url: URL) throws -> GPSPosition? {
        let tags = try everything(url)
        guard let latitude = tags["Composite:GPSLatitude"].flatMap(Double.init),
              let longitude = tags["Composite:GPSLongitude"].flatMap(Double.init) else { return nil }
        return GPSPosition(latitude: latitude, longitude: longitude)
    }

    static func setPosition(_ position: GPSPosition, _ url: URL) throws {
        try run(["-q", "-overwrite_original",
                 "-GPSLatitude=\(abs(position.latitude))", "-GPSLatitudeRef=\(position.latitude < 0 ? "S" : "N")",
                 "-GPSLongitude=\(abs(position.longitude))",
                 "-GPSLongitudeRef=\(position.longitude < 0 ? "W" : "E")", url.path])
    }

    /// What ExifTool's own validation says is wrong with the file: each
    /// warning and error, without the line that counts them.
    static func faults(_ url: URL) throws -> [String] {
        try run(["-validate", "-warning", "-error", "-a", "-s", url.path])
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("Validate") }.sorted()
    }
}
#endif
