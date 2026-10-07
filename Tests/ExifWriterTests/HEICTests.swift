import XCTest
@testable import ExifWriter

/// A HEIC's EXIF item, on boxes built by hand in every layout this library
/// takes.
final class HEICTests: XCTestCase {

    private let bixby = GPSPosition(latitude: 36.371389, longitude: -121.901944)!
    private let lonePine = GPSPosition(latitude: 36.606111, longitude: -118.062778)!

    private func set(_ position: GPSPosition?, in bytes: [UInt8]) throws -> [UInt8] {
        [UInt8](try ExifGPS.settingPosition(position, in: Data(bytes), as: .heic))
    }

    private func position(_ bytes: [UInt8]) throws -> GPSPosition? {
        try ExifGPS.position(in: Data(bytes), as: .heic)
    }

    private func assertSame(_ found: GPSPosition?, _ wanted: GPSPosition, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let found else { return XCTFail("no position. \(message)", file: file, line: line) }
        XCTAssertEqual(found.latitude, wanted.latitude, accuracy: 1e-9, message, file: file, line: line)
        XCTAssertEqual(found.longitude, wanted.longitude, accuracy: 1e-9, message, file: file, line: line)
    }

    private let camera = Fixture(little: false,
                                 block: .camera(latitude: 36.606111, longitude: -118.062778, altitude: 1136.5)).bytes()

    /// Every layout, each with EXIF that has no block and EXIF with a
    /// camera's.
    private var layouts: [(name: String, fixture: HEICFixture)] {
        var out: [(String, HEICFixture)] = []
        for (exifName, exif) in [("no block", Fixture().bytes()), ("camera", camera)] {
            func add(_ name: String, _ change: (inout HEICFixture) -> Void) {
                var fixture = HEICFixture(exif: exif)
                change(&fixture)
                out.append(("\(name), \(exifName)", fixture))
            }
            add("as Apple lays it out") { _ in }
            add("EXIF after the picture") { $0.exifLast = true }
            add("items listed after the data") { $0.metaLast = true }
            add("items listed after the data, EXIF last") { $0.metaLast = true; $0.exifLast = true }
            add("locations of version 0") { $0.version = 0 }
            add("locations of version 2") { $0.version = 2 }
            add("offsets from a base") { $0.based = true }
            add("offsets from a base, EXIF last") { $0.based = true; $0.exifLast = true }
            add("eight-byte offsets") { $0.wide = true }
            add("a 64-bit data box") { $0.largeData = true }
        }
        return out
    }

    // MARK: -

    /// The fixture is what it says it is: the reader finds each item where
    /// the fixture put it.
    func testTheFixtureReadsBack() throws {
        for (name, fixture) in layouts {
            let items = try Read.items(fixture.bytes())
            XCTAssertEqual(items[1], HEICFixture.picture, name)
            XCTAssertEqual(items[2], fixture.payload, name)
            XCTAssertEqual(items[3], HEICFixture.notes, name)
        }
    }

    /// **The position is set, every other item is the bytes it was, and the
    /// boxes still add up to the file.**
    func testThePositionIsSetAndNothingElseMoves() throws {
        for (name, fixture) in layouts {
            let before = fixture.bytes()
            let after = try set(bixby, in: before)
            assertSame(try position(after), bixby, name)

            let items = try Read.items(after)
            XCTAssertEqual(items[1], HEICFixture.picture, "the picture, \(name)")
            XCTAssertEqual(items[3], HEICFixture.notes, "the packet, \(name)")
            XCTAssertEqual(Array(items[2]?.prefix(10) ?? []), Array(fixture.payload.prefix(10)), "the EXIF's prefix, \(name)")

            let grew = after.count - before.count
            XCTAssertGreaterThan(grew, 0, name)
            let boxesBefore = try Read.boxes(before)
            let boxesAfter = try Read.boxes(after)
            XCTAssertEqual(boxesAfter.map(\.type), boxesBefore.map(\.type), name)
            XCTAssertEqual(boxesAfter.map(\.size).reduce(0, +), after.count, name)
            for (was, now) in zip(boxesBefore, boxesAfter) {
                XCTAssertEqual(now.size, was.size + (was.type == "mdat" ? grew : 0), "\(was.type), \(name)")
            }
        }
    }

    /// **Moving it again does not grow the file**, and moving it back is
    /// the same bytes.
    func testASecondWriteDoesNotGrowTheFile() throws {
        for (name, fixture) in layouts {
            let once = try set(bixby, in: fixture.bytes())
            let twice = try set(lonePine, in: once)
            XCTAssertEqual(twice.count, once.count, name)
            XCTAssertEqual(try set(bixby, in: twice), once, name)
        }
    }

    /// Taken out, the position is gone, what else the EXIF said is kept,
    /// and the other items are the bytes they were.
    func testTakingItOut() throws {
        for (name, fixture) in layouts {
            let before = fixture.bytes()
            let had = try position(before) != nil
            let cleared = try set(nil, in: had ? before : try set(bixby, in: before))
            XCTAssertNil(try position(cleared), name)
            let items = try Read.items(cleared)
            XCTAssertEqual(items[1], HEICFixture.picture, name)
            XCTAssertEqual(items[3], HEICFixture.notes, name)
            let exif = Array(try XCTUnwrap(items[2]).dropFirst(10))
            XCTAssertEqual(try Read.pixels(exif), Fixture().pixels, "the rest of the EXIF, \(name)")
            if had { XCTAssertEqual(try Read.altitude(exif), 1136.5, name) }
            XCTAssertEqual(try Read.boxes(cleared).map(\.size).reduce(0, +), cleared.count, name)
            XCTAssertEqual(try set(nil, in: cleared), cleared, "nothing left to take out, \(name)")
        }
    }

    /// A camera's altitude comes through a move.
    func testTheRestOfACamerasBlockIsKept() throws {
        let after = try set(bixby, in: HEICFixture(exif: camera).bytes())
        let exif = Array(try XCTUnwrap(try Read.items(after)[2]).dropFirst(10))
        XCTAssertEqual(try Read.altitude(exif), 1136.5)
    }

    /// **EXIF that said nothing but the position keeps its item and says
    /// nothing**, because this does not take an item out of a HEIC.
    func testExifThatWasOnlyAPositionIsLeftSayingNothing() throws {
        let seed = GPSBlock.seed()
        let only = try GPSBlock.plan(ArrayStore(bytes: seed), setting: bixby).applied(to: seed)
        let before = HEICFixture(exif: only).bytes()
        assertSame(try position(before), bixby)
        let cleared = try set(nil, in: before)
        XCTAssertNil(try position(cleared))
        let items = try Read.items(cleared)
        XCTAssertEqual(items[1], HEICFixture.picture)
        XCTAssertEqual(Array(try XCTUnwrap(items[2]).dropFirst(10)), GPSBlock.empty())
        // And it takes a position again.
        assertSame(try position(try set(lonePine, in: cleared)), lonePine)
    }

    /// The box that says where items lie reads back as the bytes it was.
    func testTheLocationsBoxReadsBackAsItWas() throws {
        for (name, fixture) in layouts {
            let bytes = fixture.bytes()
            let top = try HEICFile.boxes(bytes, in: 0..<bytes.count)
            let meta = try XCTUnwrap(top.first { $0.type == "meta" })
            let iloc = try XCTUnwrap(try HEICFile.boxes(bytes, in: meta.body.lowerBound + 4..<meta.end)
                .first { $0.type == "iloc" })
            let body = Array(bytes[iloc.body])
            XCTAssertEqual(try HEICFile.Locations(body).body(), body, name)
        }
    }

    // MARK: - What is refused

    /// **A HEIC with no EXIF item is refused**, and nothing is written.
    /// Taking a position out of one changes nothing.
    func testAFileWithNoExifIsRefused() throws {
        let bytes = HEICFixture(noExif: true).bytes()
        XCTAssertNil(try position(bytes))
        XCTAssertEqual(try set(nil, in: bytes), bytes)
        XCTAssertThrowsError(try set(bixby, in: bytes)) {
            XCTAssertEqual($0 as? ExifWriterError, .unsupported("a HEIC with no EXIF"))
        }
    }

    func testWhatIsNotAHEICIsRefused() {
        for bytes in [Fixture().bytes(), PNGFixture().bytes(), [UInt8]()] {
            XCTAssertThrowsError(try set(bixby, in: bytes))
        }
    }

    func testAFileCutShortIsRefused() {
        let whole = HEICFixture().bytes()
        XCTAssertThrowsError(try set(bixby, in: Array(whole[..<(whole.count - 40)])))
    }

    /// A file of moving pictures holds offsets this does not know how to
    /// move, so it is refused.
    func testASequenceIsRefused() {
        let bytes = HEICFixture().bytes() + [0, 0, 0, 8] + [UInt8]("moov".utf8)
        XCTAssertThrowsError(try set(bixby, in: bytes)) { error in
            guard case .unsupported = error as? ExifWriterError else { return XCTFail("\(error)") }
        }
    }

    func testAFileIsReplacedWhole() throws {
        let scratch = try Scratch(HEICFixture(exif: camera).bytes(), extension: "heic")
        XCTAssertTrue(try ExifGPS.setPosition(bixby, inFileAt: scratch.url, as: .heic))
        assertSame(try ExifGPS.position(inFileAt: scratch.url, as: .heic), bixby)
        XCTAssertTrue(try ExifGPS.setPosition(nil, inFileAt: scratch.url, as: .heic))
        XCTAssertNil(try ExifGPS.position(inFileAt: scratch.url, as: .heic))
        XCTAssertFalse(try ExifGPS.setPosition(nil, inFileAt: scratch.url, as: .heic))
        XCTAssertEqual(ImageContainer(pathExtension: "HEIC"), .heic)
    }
}
