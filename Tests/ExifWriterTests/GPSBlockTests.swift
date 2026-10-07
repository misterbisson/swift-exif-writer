import XCTest
@testable import ExifWriter

/// The GPS block of a TIFF, on files built by hand in both byte orders.
final class GPSBlockTests: XCTestCase {

    private let bixby = GPSPosition(latitude: 36.371389, longitude: -121.901944)!
    private let lonePine = GPSPosition(latitude: 36.606111, longitude: -118.062778)!

    private func set(_ position: GPSPosition?, in bytes: [UInt8]) throws -> [UInt8] {
        [UInt8](try ExifGPS.settingPosition(position, in: Data(bytes), as: .tiff))
    }

    private func position(_ bytes: [UInt8]) throws -> GPSPosition? {
        try ExifGPS.position(in: Data(bytes), as: .tiff)
    }

    private func assertSame(_ found: GPSPosition?, _ wanted: GPSPosition,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let found else { return XCTFail("no position", file: file, line: line) }
        XCTAssertEqual(found.latitude, wanted.latitude, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(found.longitude, wanted.longitude, accuracy: 1e-9, file: file, line: line)
    }

    /// Where the bytes of `before` differ from the same stretch of `after`.
    private func changed(_ before: [UInt8], _ after: [UInt8]) -> [Int] {
        (0..<min(before.count, after.count)).filter { before[$0] != after[$0] }
    }

    private var bothOrders: [Bool] { [true, false] }

    // MARK: - Setting

    /// **A file with no block takes one, and only the header's pointer to
    /// the first directory changes in what was there.**
    func testAFileWithNoPositionTakesOne() throws {
        for little in bothOrders {
            let before = Fixture(little: little).bytes()
            XCTAssertNil(try position(before))
            let after = try set(bixby, in: before)
            assertSame(try position(after), bixby)
            XCTAssertEqual(Set(changed(before, after)).subtracting(4..<8), [], "little \(little)")
            XCTAssertEqual(try Read.pixels(after), Fixture(little: little).pixels)
            XCTAssertEqual(after.count % 2, 0)
        }
    }

    /// **A camera's position is replaced, and only the four bytes that
    /// point at the block change in what was there.** The altitude comes
    /// with it.
    func testACamerasPositionIsReplaced() throws {
        for little in bothOrders {
            let fixture = Fixture(little: little,
                                  block: .camera(latitude: 36.606111, longitude: -118.062778, altitude: 1136.5))
            let before = fixture.bytes()
            XCTAssertEqual(try position(before)?.latitude ?? 0, lonePine.latitude, accuracy: 1e-5)
            let after = try set(bixby, in: before)
            assertSame(try position(after), bixby)
            XCTAssertEqual(changed(before, after).count <= 4, true, "little \(little)")
            XCTAssertEqual(Array(after[..<8]), Array(before[..<8]), "the first directory did not move")
            XCTAssertEqual(try Read.altitude(after), 1136.5)
            XCTAssertEqual(try Read.pixels(after), fixture.pixels)
        }
    }

    /// The block names its version when this is the first thing in it.
    func testANewBlockSaysItsVersion() throws {
        let after = try set(bixby, in: Fixture().bytes())
        let block = try XCTUnwrap(try Read.block(after))
        XCTAssertEqual(block.entries.map(\.tag), [0, 1, 2, 3, 4])
        XCTAssertEqual(block.entry(0)?.value, [2, 3, 0, 0])
    }

    /// **Moving a photograph again does not grow the file.**
    func testASecondWriteTakesTheFirstOnesPlace() throws {
        for fixture in [Fixture(), Fixture(little: false),
                        Fixture(block: .camera(latitude: 10, longitude: 20, altitude: 30))] {
            let once = try set(bixby, in: fixture.bytes())
            let twice = try set(lonePine, in: once)
            let thrice = try set(bixby, in: twice)
            XCTAssertEqual(twice.count, once.count)
            XCTAssertEqual(thrice, once, "back where it was, byte for byte")
            assertSame(try position(twice), lonePine)
        }
    }

    /// A block another writer left at the end of the file is replaced where
    /// it stands, and what else it said is carried across.
    func testABlockAtTheEndKeepsWhatElseItSaid() throws {
        for little in bothOrders {
            let fixture = Fixture(little: little,
                                  block: .camera(latitude: -33.856784, longitude: 151.215297, altitude: 12.25),
                                  blockLast: true)
            let before = fixture.bytes()
            XCTAssertEqual(try position(before)?.longitude ?? 0, 151.215297, accuracy: 1e-5)
            let after = try set(bixby, in: before)
            assertSame(try position(after), bixby)
            XCTAssertEqual(try Read.altitude(after), 12.25)
            XCTAssertEqual(try Read.pixels(after), fixture.pixels)
            XCTAssertEqual(try set(lonePine, in: after).count, after.count)
        }
    }

    /// A file of odd length gets a byte of padding, because offsets are
    /// even.
    func testAnOddLengthIsPadded() throws {
        let before = Fixture().bytes() + [0xEE]
        let after = try set(bixby, in: before)
        assertSame(try position(after), bixby)
        XCTAssertEqual(Array(after[8..<before.count]), Array(before[8...]))
        let tiff = try TIFFStructure(ArrayStore(bytes: after))
        XCTAssertEqual(tiff.first % 2, 0)
    }

    // MARK: - What is written reads back

    func testEveryPositionReadsBackAsWritten() throws {
        let places: [(Double, Double)] = [
            (36.371389, -121.901944), (-33.856784, 151.215297), (0, 0), (90, 180), (-90, -180),
            (0.000001, -0.000001), (89.999999, 179.999999), (51.5, -0.125), (-0.5, 0.5),
            (12.345678, 98.765432),
        ]
        for little in bothOrders {
            for (latitude, longitude) in places {
                let wanted = try XCTUnwrap(GPSPosition(latitude: latitude, longitude: longitude))
                assertSame(try position(try set(wanted, in: Fixture(little: little).bytes())), wanted)
            }
        }
    }

    /// A hair under a whole minute is 59 minutes and 59.99… seconds, never
    /// 60 seconds.
    func testSecondsNeverReachSixty() {
        for degrees in [36.99999999999, 0.0166666666666, 179.99999999999, 59.99999999 / 60] {
            let parts = GPSPosition.rationals(degrees)
            XCTAssertLessThan(parts[1].0, 60)
            XCTAssertLessThan(Double(parts[2].0) / Double(parts[2].1), 60)
            let back = GPSPosition.degrees(parts.map { (Double($0.0), Double($0.1)) })
            XCTAssertEqual(back ?? -1, degrees, accuracy: 1e-9)
        }
    }

    func testAPointOffTheGlobeIsNotAPosition() {
        XCTAssertNil(GPSPosition(latitude: 90.01, longitude: 0))
        XCTAssertNil(GPSPosition(latitude: 0, longitude: -180.01))
        XCTAssertNil(GPSPosition(latitude: .nan, longitude: 0))
        XCTAssertNotNil(GPSPosition(latitude: 0, longitude: 0))
    }

    // MARK: - Taking it out

    /// **Set and then taken out: no position, and no block.**
    func testAPositionSetAndTakenOutLeavesNoBlock() throws {
        for little in bothOrders {
            let fixture = Fixture(little: little)
            let placed = try set(bixby, in: fixture.bytes())
            let cleared = try set(nil, in: placed)
            XCTAssertNil(try position(cleared))
            XCTAssertNil(try Read.block(cleared))
            XCTAssertEqual(try Read.pixels(cleared), fixture.pixels)
            XCTAssertLessThan(cleared.count, placed.count, "the block was the end of the file and is cut off")
            // And it takes one again.
            assertSame(try position(try set(lonePine, in: cleared)), lonePine)
        }
    }

    /// Taking the position out leaves what else the block said.
    func testTakingThePositionOutKeepsTheAltitude() throws {
        for last in [false, true] {
            let fixture = Fixture(block: .camera(latitude: 36.6, longitude: -118.06, altitude: 1136.5),
                                  blockLast: last)
            let cleared = try set(nil, in: fixture.bytes())
            XCTAssertNil(try position(cleared))
            XCTAssertEqual(try Read.altitude(cleared), 1136.5)
            XCTAssertEqual(try Read.block(cleared)?.entries.map(\.tag), [0, 5, 6])
            XCTAssertEqual(try Read.pixels(cleared), fixture.pixels)
        }
    }

    /// A block that says only how high takes a position and keeps the
    /// height.
    func testABlockWithNoPositionTakesOne() throws {
        let after = try set(bixby, in: Fixture(block: .altitudeOnly(250)).bytes())
        assertSame(try position(after), bixby)
        XCTAssertEqual(try Read.altitude(after), 250)
    }

    /// **Taking a position out of a file that has none changes nothing.**
    func testTakingNothingOutChangesNothing() throws {
        for fixture in [Fixture(), Fixture(block: .altitudeOnly(250)), Fixture(little: false)] {
            let before = fixture.bytes()
            XCTAssertEqual(try set(nil, in: before), before)
        }
    }

    // MARK: - What is refused

    func testBigTIFFIsRefused() {
        var bytes = Fixture().bytes()
        bytes[2] = 43
        XCTAssertThrowsError(try set(bixby, in: bytes)) {
            XCTAssertEqual($0 as? ExifWriterError, .unsupported("BigTIFF"))
        }
    }

    func testWhatIsNotATIFFIsRefused() {
        for bytes in [[UInt8](), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], [UInt8]("II".utf8)] {
            XCTAssertThrowsError(try set(bixby, in: bytes)) {
                XCTAssertEqual($0 as? ExifWriterError, .notThisFormat("a TIFF structure"))
            }
        }
    }

    /// A first directory that runs off the end is refused, and nothing is
    /// written.
    func testADirectoryCutShortIsRefused() {
        let whole = Fixture().bytes()
        let cut = Array(whole[..<(whole.count - 10)])
        XCTAssertThrowsError(try set(bixby, in: cut)) { error in
            guard case .malformed = error as? ExifWriterError else { return XCTFail("\(error)") }
        }
    }

    /// A pointer that leads nowhere is treated as no block, and a new one
    /// is written.
    func testAPointerThatLeadsNowhereIsReplaced() throws {
        let fixture = Fixture(block: .altitudeOnly(1), blockLast: true)
        var bytes = fixture.bytes()
        // Cut the block off, leaving its pointer.
        let tiff = try TIFFStructure(ArrayStore(bytes: bytes))
        let root = try tiff.directory(at: tiff.first)
        bytes = Array(bytes[..<(root.offset + root.length)])
        XCTAssertNil(try position(bytes))
        let after = try set(bixby, in: bytes)
        assertSame(try position(after), bixby)
        XCTAssertEqual(try Read.pixels(after), fixture.pixels)
    }

    // MARK: - A file on disk

    func testAFileIsEditedWhereItStands() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exif-writer-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = Fixture(block: .camera(latitude: 10, longitude: 20, altitude: 30))
        try Data(fixture.bytes()).write(to: url)

        XCTAssertTrue(try ExifGPS.setPosition(bixby, inFileAt: url, as: .tiff))
        assertSame(try ExifGPS.position(inFileAt: url, as: .tiff), bixby)
        let inMemory = try set(bixby, in: fixture.bytes())
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), inMemory, "the file and the bytes take the same edit")

        XCTAssertTrue(try ExifGPS.setPosition(nil, inFileAt: url, as: .tiff))
        XCTAssertNil(try ExifGPS.position(inFileAt: url, as: .tiff))
        XCTAssertFalse(try ExifGPS.setPosition(nil, inFileAt: url, as: .tiff), "nothing left to take out")
    }

    func testAnExtensionNamesItsContainer() {
        XCTAssertEqual(ImageContainer(pathExtension: "TIF"), .tiff)
        XCTAssertEqual(ImageContainer(pathExtension: "tiff"), .tiff)
        XCTAssertNil(ImageContainer(pathExtension: "cr2"))
        XCTAssertNil(ImageContainer(pathExtension: "dng"))
    }
}
