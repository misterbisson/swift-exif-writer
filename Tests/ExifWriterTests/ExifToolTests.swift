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
            XCTAssertEqual(ExifTool.differing(ExifTool.withoutPosition(placed, fresh: fresh),
                                              ExifTool.withoutPosition(before, fresh: fresh)), [], sample.name)
            XCTAssertNotNil(placed["ImageDataHash"], "the digest of the picture was compared")

            try ExifGPS.setPosition(nil, inFileAt: file.url, as: sample.container)
            let cleared = try ExifTool.everything(file.url)
            XCTAssertEqual(ExifTool.differing(ExifTool.withoutPosition(cleared),
                                              ExifTool.withoutPosition(before)), [], sample.name)
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

    /// **The packet's copy is what the EXIF is**, as ExifTool reads the two
    /// apart: set where the packet stated one, gone where it is taken out,
    /// and never added to a packet that stated none.
    func testThePacketsCopyAgreesWithTheEXIF() throws {
        XCTAssertTrue(Sample.all.contains { $0.statesItInItsPacket }, "no sample states it there")
        for sample in Sample.all {
            let file = try sample.scratch()
            XCTAssertEqual(try ExifTool.packetPosition(file.url) != nil, sample.statesItInItsPacket,
                           "the sample is not what it is said to be: \(sample.name)")
            for place in [bixby, sydney] {
                try ExifGPS.setPosition(place, inFileAt: file.url, as: sample.container)
                let read = try ExifTool.packetPosition(file.url)
                guard sample.statesItInItsPacket else {
                    XCTAssertNil(read, sample.name)
                    continue
                }
                XCTAssertEqual(read?.latitude ?? .nan, place.latitude, accuracy: 1e-7, sample.name)
                XCTAssertEqual(read?.longitude ?? .nan, place.longitude, accuracy: 1e-7, sample.name)
                let block = try ExifTool.blockPosition(file.url)
                XCTAssertEqual(block?.latitude ?? .nan, place.latitude, accuracy: 1e-7, sample.name)
                XCTAssertEqual(block?.longitude ?? .nan, place.longitude, accuracy: 1e-7, sample.name)
            }
            try ExifGPS.setPosition(nil, inFileAt: file.url, as: sample.container)
            XCTAssertNil(try ExifTool.packetPosition(file.url), sample.name)
            XCTAssertNil(try ExifTool.blockPosition(file.url), sample.name)
        }
    }

    /// **A position that is only in what follows a PNG's packet goes when
    /// the file is written.** ImageIO leaves the end of an older packet
    /// after the closing line, ExifTool reads tags out of it, and here that
    /// end is a whole position. Taken out, the file states none anywhere.
    func testAPositionLeftAfterAPNGsPacketIsGone() throws {
        let residue = [UInt8]("""
              <exif:GPSLatitude>36,36.366660N</exif:GPSLatitude>
                 <exif:GPSLongitude>118,3.766680W</exif:GPSLongitude>
              </rdf:Description>
           </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="r"?>
        """.utf8)
        for style in [XMPFixture.Style.lightroom, .exifTool] {
            let packet = XMPFixture(style: style).stating(nil).bytes() + residue
            for place in [nil, sydney] {
                let file = try Scratch(PNGFixture(packet: packet).bytes(), extension: "png")
                XCTAssertNil(try ExifGPS.position(inFileAt: file.url, as: .png), "\(style)")
                let stale = try ExifTool.packetPosition(file.url)
                XCTAssertEqual(stale?.latitude ?? .nan, 36.606111, accuracy: 1e-6,
                               "ExifTool does not read what follows the packet: \(style)")
                try ExifGPS.setPosition(place, inFileAt: file.url, as: .png)
                XCTAssertNil(try ExifTool.packetPosition(file.url), "\(style)")
                let block = try ExifTool.blockPosition(file.url)
                XCTAssertEqual(block?.latitude, place?.latitude, "\(style)")
                XCTAssertFalse(try ExifTool.faults(file.url).contains { $0.contains("out of scope") }, "\(style)")
            }
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
            XCTAssertEqual(ExifTool.differing(ExifTool.comparable(try ExifTool.everything(ours.url), fresh: fresh),
                                              ExifTool.comparable(try ExifTool.everything(theirs.url), fresh: fresh)), [], sample.name)
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
            XCTAssertEqual(ExifTool.differing(ExifTool.withoutPosition(try ExifTool.everything(file.url)),
                                              ExifTool.withoutPosition(before)), [], sample.name)
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
    /// The file's XMP packet states a position.
    var statesItInItsPacket = false

    func scratch() throws -> Scratch {
        try Scratch(bytes, extension: container.fileExtension)
    }

    /// One of the HEICs ImageIO wrote, which are files beside the tests.
    static func drawn(_ name: String) -> [UInt8] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "heic", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else { return [] }
        return [UInt8](data)
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
        Sample(name: "HEIC ImageIO wrote", container: .heic, bytes: drawn("drawn")),
        Sample(name: "HEIC ImageIO wrote with a camera's position", container: .heic,
               bytes: drawn("drawn-camera")),
    ] + withPackets

    private static let lightroom = XMPFixture(style: .lightroom, padding: 17)
    private static let exifTool = XMPFixture(style: .exifTool)
    private static let imageIO = XMPFixture(style: .imageIO)

    /// Files whose XMP packet states the position too, or alone, laid out
    /// as three writers lay a packet out.
    private static let withPackets: [Sample] = [
        Sample(name: "TIFF, a packet with room that states it too", container: .tiff,
               bytes: Fixture(block: camera, packet: XMPFixture(style: .lightroom, padding: 60).bytes()).bytes(),
               statesItInItsPacket: true),
        Sample(name: "TIFF, big, a packet with no room that states it too", container: .tiff,
               bytes: Fixture(little: false, block: camera, packet: imageIO.bytes()).bytes(),
               statesItInItsPacket: true),
        Sample(name: "TIFF, block last, a packet with no room", container: .tiff,
               bytes: Fixture(block: camera, blockLast: true, packet: exifTool.bytes()).bytes(),
               statesItInItsPacket: true),
        Sample(name: "TIFF, only its packet states it", container: .tiff,
               bytes: Fixture(packet: exifTool.bytes()).bytes(), statesItInItsPacket: true),
        Sample(name: "TIFF, a packet that states none", container: .tiff,
               bytes: Fixture(block: camera, packet: lightroom.stating(nil).bytes()).bytes()),
        Sample(name: "PNG as Lightroom exports one, only its packet stating it", container: .png,
               bytes: PNGFixture(packet: lightroom.bytes()).bytes(), statesItInItsPacket: true),
        Sample(name: "PNG, EXIF and a packet both stating it", container: .png,
               bytes: PNGFixture(exif: .holding(Fixture(block: camera).bytes()), packet: imageIO.bytes()).bytes(),
               statesItInItsPacket: true),
        Sample(name: "PNG, a packet that states none", container: .png,
               bytes: PNGFixture(packet: exifTool.stating(nil).bytes()).bytes()),
        Sample(name: "HEIC ImageIO wrote with the position in its packet too", container: .heic,
               bytes: drawn("drawn-xmp"), statesItInItsPacket: true),
    ]
}

extension ImageContainer {
    var fileExtension: String {
        switch self {
        case .tiff: "tif"
        case .png: "png"
        case .heic: "heic"
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

    /// The position, in the EXIF and in the XMP packet, and what ExifTool
    /// works out from either.
    private static let position: Set<String> = [
        "GPS:GPSLatitude", "GPS:GPSLatitudeRef", "GPS:GPSLongitude", "GPS:GPSLongitudeRef",
        "XMP-exif:GPSLatitude", "XMP-exif:GPSLatitudeRef", "XMP-exif:GPSLongitude", "XMP-exif:GPSLongitudeRef",
        "Composite:GPSLatitude", "Composite:GPSLongitude", "Composite:GPSPosition",
        "Composite:GPSLatitudeRef", "Composite:GPSLongitudeRef",
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

    /// **The data box of a HEIC, as ExifTool reports it.** The EXIF lies in
    /// that box beside the picture, so the box is as much longer as the
    /// EXIF is, under either writer. The picture's own bytes are held to
    /// account by the digest, and by ImageIO decoding them.
    private static let dataBox: Set<String> = [
        "QuickTime:MediaData", "QuickTime:MediaDataSize", "QuickTime:MediaDataOffset",
    ]

    /// Everything but the position, the version a new block states, and the
    /// pointer to the block, which is the position's own plumbing. `fresh`
    /// where the file had no EXIF before.
    static func withoutPosition(_ tags: [String: String], fresh: Bool = false) -> [String: String] {
        ofTheFile(tags).filter {
            !position.contains($0.key) && $0.key != "GPS:GPSVersionID" && !$0.key.hasSuffix(":GPSInfo")
                && !dataBox.contains($0.key) && !(fresh && startingExif.contains($0.key))
        }
    }

    /// For comparing two writers' files: positions rounded to what both
    /// keep, and the plumbing left out. Where the picture's data sits is
    /// plumbing here, because ExifTool lays the file out afresh.
    ///
    /// ExifTool writes a packet out afresh when it changes one, and signs
    /// it as its own. This library changes the values and leaves the name
    /// of whoever wrote the packet.
    static func comparable(_ tags: [String: String], fresh: Bool = false) -> [String: String] {
        var out = withoutPosition(tags, fresh: fresh)
            .filter { !$0.key.hasSuffix(":StripOffsets") && $0.key != "XMP-x:XMPToolkit" }
        for key in ["Composite:GPSLatitude", "Composite:GPSLongitude",
                    "XMP-exif:GPSLatitude", "XMP-exif:GPSLongitude"] {
            out[key] = tags[key].flatMap(Double.init).map { String(format: "%.6f", $0) }
        }
        out["GPS:GPSVersionID"] = tags["GPS:GPSVersionID"]
        return out
    }

    /// The tags two reports disagree about, each with both its values, so a
    /// failure names what changed and not two whole files.
    static func differing(_ a: [String: String], _ b: [String: String]) -> [String] {
        Set(a.keys).union(b.keys).sorted().filter { a[$0] != b[$0] }
            .map { "\($0): \(a[$0] ?? "absent") | \(b[$0] ?? "absent")" }
    }

    /// The position the file states: the EXIF's, and where the EXIF has
    /// none, the XMP packet's.
    ///
    /// Not ExifTool's own `Composite:GPSLatitude`, which it works out from
    /// the EXIF alone: for a file that states its position only in its
    /// packet, as Lightroom's PNGs do, there is none, and a check made
    /// against it would pass a file that still said where it was.
    static func position(_ url: URL) throws -> GPSPosition? {
        try blockPosition(url) ?? packetPosition(url)
    }

    /// The position the XMP packet states, as ExifTool reads it, with
    /// the EXIF left out.
    static func packetPosition(_ url: URL) throws -> GPSPosition? {
        let tags = try everything(url)
        guard let latitude = tags["XMP-exif:GPSLatitude"].flatMap(Double.init),
              let longitude = tags["XMP-exif:GPSLongitude"].flatMap(Double.init) else { return nil }
        return GPSPosition(latitude: latitude, longitude: longitude)
    }

    /// The position the EXIF states, as ExifTool reads it, with the packet
    /// left out.
    static func blockPosition(_ url: URL) throws -> GPSPosition? {
        let tags = try everything(url)
        guard let latitude = tags["GPS:GPSLatitude"].flatMap(Double.init),
              let longitude = tags["GPS:GPSLongitude"].flatMap(Double.init) else { return nil }
        return GPSPosition(latitude: tags["GPS:GPSLatitudeRef"] == "S" ? -latitude : latitude,
                           longitude: tags["GPS:GPSLongitudeRef"] == "W" ? -longitude : longitude)
    }

    /// **Signed numbers, and each name with a star.** The star takes in
    /// the tag that holds the hemisphere, and ExifTool works that out of
    /// the sign. Given a number without a sign and the hemisphere as a tag
    /// of its own, ExifTool 13.55 writes the EXIF right and the XMP packet's
    /// copy as north and east whatever was asked: XMP holds the hemisphere
    /// in the value, and the value it was given had none.
    static func setPosition(_ position: GPSPosition, _ url: URL) throws {
        try run(["-q", "-overwrite_original",
                 "-GPSLatitude*=\(position.latitude)", "-GPSLongitude*=\(position.longitude)", url.path])
    }

    /// What ExifTool's own validation says is wrong with the file: each
    /// warning and error, without the line that counts them.
    static func faults(_ url: URL) throws -> [String] {
        try run(["-validate", "-warning", "-error", "-a", "-s", url.path])
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("Validate") }.sorted()
    }
}
#endif
