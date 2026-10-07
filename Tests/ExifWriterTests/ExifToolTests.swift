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

    private var fixtures: [(name: String, bytes: [UInt8])] {
        [("little, no block", Fixture().bytes()),
         ("big, no block", Fixture(little: false).bytes()),
         ("little, camera", Fixture(block: .camera(latitude: 36.606111, longitude: -118.062778,
                                                   altitude: 1136.5)).bytes()),
         ("big, camera", Fixture(little: false,
                                 block: .camera(latitude: 36.606111, longitude: -118.062778,
                                                altitude: 1136.5)).bytes()),
         ("little, block last", Fixture(block: .camera(latitude: 1, longitude: 2, altitude: 3),
                                        blockLast: true).bytes()),
         ("little, altitude only", Fixture(block: .altitudeOnly(250)).bytes())]
    }

    // MARK: - ExifTool reads what this library wrote

    func testExifToolReadsThePositionThisWrote() throws {
        for fixture in fixtures {
            for place in [bixby, sydney] {
                let file = try Scratch(fixture.bytes)
                try ExifGPS.setPosition(place, inFileAt: file.url, as: .tiff)
                let read = try ExifTool.position(file.url)
                XCTAssertEqual(read?.latitude ?? .nan, place.latitude, accuracy: 1e-7, fixture.name)
                XCTAssertEqual(read?.longitude ?? .nan, place.longitude, accuracy: 1e-7, fixture.name)
            }
        }
    }

    /// **Nothing ExifTool reports about the file changes but its position**:
    /// every other tag, where the picture's data is, and a digest of that
    /// data.
    func testNothingButThePositionChanges() throws {
        for fixture in fixtures {
            let file = try Scratch(fixture.bytes)
            let before = try ExifTool.everything(file.url)
            try ExifGPS.setPosition(bixby, inFileAt: file.url, as: .tiff)
            let placed = try ExifTool.everything(file.url)
            XCTAssertEqual(ExifTool.withoutPosition(placed), ExifTool.withoutPosition(before), fixture.name)
            XCTAssertNotNil(placed["ImageDataHash"], "the digest of the picture was compared")

            try ExifGPS.setPosition(nil, inFileAt: file.url, as: .tiff)
            let cleared = try ExifTool.everything(file.url)
            XCTAssertEqual(ExifTool.withoutPosition(cleared), ExifTool.withoutPosition(before), fixture.name)
            XCTAssertNil(try ExifTool.position(file.url), fixture.name)
        }
    }

    /// **ExifTool's validation finds nothing wrong with a file this library
    /// wrote that it does not find wrong with one it wrote itself.**
    ///
    /// Its own file is the measure, and not the file before, because its
    /// validation asks more of a GPS block than of a file with none: it
    /// warns that a block it has just written lacks `GPSProcessingMethod`.
    /// Once the position is taken out the file is held to what it was.
    func testExifToolFindsNoFaultItsOwnWritingLacks() throws {
        for fixture in fixtures {
            let ours = try Scratch(fixture.bytes)
            let theirs = try Scratch(fixture.bytes)
            let before = try ExifTool.faults(ours.url)
            try ExifTool.setPosition(bixby, theirs.url)
            let reference = try ExifTool.faults(theirs.url)

            try ExifGPS.setPosition(sydney, inFileAt: ours.url, as: .tiff)
            XCTAssertEqual(try ExifTool.faults(ours.url), reference, "placed, \(fixture.name)")
            try ExifGPS.setPosition(bixby, inFileAt: ours.url, as: .tiff)
            XCTAssertEqual(try ExifTool.faults(ours.url), reference, "moved, \(fixture.name)")
            try ExifGPS.setPosition(nil, inFileAt: ours.url, as: .tiff)
            XCTAssertEqual(try ExifTool.faults(ours.url), before, "cleared, \(fixture.name)")
        }
    }

    // MARK: - This library reads what ExifTool wrote

    func testThisReadsThePositionExifToolWrote() throws {
        for fixture in fixtures {
            for place in [bixby, sydney] {
                let file = try Scratch(fixture.bytes)
                try ExifTool.setPosition(place, file.url)
                let read = try ExifGPS.position(inFileAt: file.url, as: .tiff)
                XCTAssertEqual(read?.latitude ?? .nan, place.latitude, accuracy: 1e-7, fixture.name)
                XCTAssertEqual(read?.longitude ?? .nan, place.longitude, accuracy: 1e-7, fixture.name)
            }
        }
    }

    /// **The two writers leave files ExifTool describes the same way.**
    func testBothWritersLeaveTheSameTags() throws {
        for fixture in fixtures {
            let ours = try Scratch(fixture.bytes)
            let theirs = try Scratch(fixture.bytes)
            try ExifGPS.setPosition(bixby, inFileAt: ours.url, as: .tiff)
            try ExifTool.setPosition(bixby, theirs.url)
            XCTAssertEqual(ExifTool.comparable(try ExifTool.everything(ours.url)),
                           ExifTool.comparable(try ExifTool.everything(theirs.url)), fixture.name)
        }
    }

    /// This library moves and clears a position ExifTool wrote, and ExifTool
    /// agrees with the result.
    func testThisEditsWhatExifToolWrote() throws {
        for fixture in fixtures {
            let file = try Scratch(fixture.bytes)
            try ExifTool.setPosition(sydney, file.url)
            let before = try ExifTool.everything(file.url)
            try ExifGPS.setPosition(bixby, inFileAt: file.url, as: .tiff)
            let read = try ExifTool.position(file.url)
            XCTAssertEqual(read?.latitude ?? .nan, bixby.latitude, accuracy: 1e-7, fixture.name)
            XCTAssertEqual(ExifTool.withoutPosition(try ExifTool.everything(file.url)),
                           ExifTool.withoutPosition(before), fixture.name)
            try ExifGPS.setPosition(nil, inFileAt: file.url, as: .tiff)
            XCTAssertNil(try ExifTool.position(file.url), fixture.name)
        }
    }
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

    /// Everything but the position, the version a new block states, and the
    /// pointer to the block, which is the position's own plumbing.
    static func withoutPosition(_ tags: [String: String]) -> [String: String] {
        ofTheFile(tags).filter {
            !position.contains($0.key) && $0.key != "GPS:GPSVersionID" && !$0.key.hasSuffix(":GPSInfo")
        }
    }

    /// For comparing two writers' files: positions rounded to what both
    /// keep, and the plumbing left out. Where the picture's data sits is
    /// plumbing here, because ExifTool lays the file out afresh.
    static func comparable(_ tags: [String: String]) -> [String: String] {
        var out = withoutPosition(tags).filter { !$0.key.hasSuffix(":StripOffsets") }
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

    /// What ExifTool's own validation says is wrong with the file.
    static func faults(_ url: URL) throws -> [String] {
        try run(["-validate", "-warning", "-error", "-a", "-s", url.path])
            .split(separator: "\n").map(String.init).sorted()
    }
}
#endif
