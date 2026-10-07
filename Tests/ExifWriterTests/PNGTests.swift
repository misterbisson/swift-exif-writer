import XCTest
@testable import ExifWriter

/// A PNG's EXIF chunk, on files built by hand.
final class PNGTests: XCTestCase {

    private let bixby = GPSPosition(latitude: 36.371389, longitude: -121.901944)!
    private let lonePine = GPSPosition(latitude: 36.606111, longitude: -118.062778)!

    private func set(_ position: GPSPosition?, in bytes: [UInt8]) throws -> [UInt8] {
        [UInt8](try ExifGPS.settingPosition(position, in: Data(bytes), as: .png))
    }

    private func position(_ bytes: [UInt8]) throws -> GPSPosition? {
        try ExifGPS.position(in: Data(bytes), as: .png)
    }

    private func assertSame(_ found: GPSPosition?, _ wanted: GPSPosition,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let found else { return XCTFail("no position", file: file, line: line) }
        XCTAssertEqual(found.latitude, wanted.latitude, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(found.longitude, wanted.longitude, accuracy: 1e-9, file: file, line: line)
    }

    /// EXIF as a camera's converter leaves it in a PNG: the TIFF fixture
    /// with its picture left out is not needed, so the whole small TIFF
    /// stands in. What matters is that it is a structure with other tags in
    /// it and a block in the middle.
    private func cameraExif(little: Bool) -> [UInt8] {
        Fixture(little: little,
                block: .camera(latitude: 36.606111, longitude: -118.062778, altitude: 1136.5)).bytes()
    }

    // MARK: -

    /// **A PNG with no EXIF takes a chunk of it before the picture's data,
    /// and every other chunk is the bytes it was.**
    func testAFileWithNoExifTakesAChunk() throws {
        let before = PNGFixture().bytes()
        XCTAssertNil(try position(before))
        let after = try set(bixby, in: before)
        assertSame(try position(after), bixby)
        XCTAssertEqual(try Read.otherChunks(after), try Read.otherChunks(before))
        XCTAssertEqual(try Read.chunks(after).map(\.type), ["IHDR", "pHYs", "tEXt", "eXIf", "IDAT", "IDAT", "IEND"])
    }

    /// The new chunk's checksum is right, by a known value: the CRC-32 of
    /// `IEND` with no data is in every PNG ever written.
    func testTheChecksumIsTheFormatsOwn() {
        XCTAssertEqual(PNGFile.crc([UInt8]("IEND".utf8)), 0xAE42_6082)
        XCTAssertEqual(PNGFile.chunk([UInt8]("IEND".utf8), []),
                       [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
    }

    /// **Set and taken out again, the file is the bytes it started as.**
    func testSetAndTakenOutIsTheFileItWas() throws {
        let before = PNGFixture().bytes()
        XCTAssertEqual(try set(nil, in: try set(bixby, in: before)), before)
        XCTAssertEqual(try set(nil, in: before), before, "nothing to take out")
    }

    /// A camera's position is replaced in the chunk it is in, and the rest
    /// of the EXIF is kept.
    func testACamerasPositionIsReplaced() throws {
        for little in [true, false] {
            let held = cameraExif(little: little)
            let before = PNGFixture(exif: .holding(held)).bytes()
            XCTAssertEqual(try position(before)?.latitude ?? 0, lonePine.latitude, accuracy: 1e-5)
            let after = try set(bixby, in: before)
            assertSame(try position(after), bixby)
            XCTAssertEqual(try Read.otherChunks(after), try Read.otherChunks(before))
            XCTAssertEqual(try Read.chunks(after).map(\.type), try Read.chunks(before).map(\.type))
            let exif = try XCTUnwrap(try Read.exif(after))
            XCTAssertEqual(try Read.altitude(exif), 1136.5)
            XCTAssertEqual(try Read.pixels(exif), Fixture(little: little).pixels,
                           "the rest of the EXIF did not move")
        }
    }

    /// **EXIF that sat after the picture's data is moved before it**, which
    /// is where the format asks for it and where ExifTool puts it. Every
    /// other chunk is the bytes it was, in the order it was in.
    func testExifAfterThePictureIsMovedBeforeIt() throws {
        let before = PNGFixture(exif: .holding(cameraExif(little: true)), exifLast: true).bytes()
        XCTAssertEqual(try Read.chunks(before).map(\.type),
                       ["IHDR", "pHYs", "tEXt", "IDAT", "IDAT", "eXIf", "IEND"])
        let after = try set(bixby, in: before)
        assertSame(try position(after), bixby)
        XCTAssertEqual(try Read.chunks(after).map(\.type),
                       ["IHDR", "pHYs", "tEXt", "eXIf", "IDAT", "IDAT", "IEND"])
        XCTAssertEqual(try Read.otherChunks(after), try Read.otherChunks(before))
    }

    func testASecondWriteDoesNotGrowTheFile() throws {
        for fixture in [PNGFixture(), PNGFixture(exif: .holding(cameraExif(little: true)))] {
            let once = try set(bixby, in: fixture.bytes())
            let twice = try set(lonePine, in: once)
            XCTAssertEqual(twice.count, once.count)
            XCTAssertEqual(try set(bixby, in: twice), once)
        }
    }

    /// Taken out of a camera's EXIF, the chunk stays and says the rest.
    func testTakingItOutOfACamerasExifKeepsTheRest() throws {
        let before = PNGFixture(exif: .holding(cameraExif(little: false))).bytes()
        let after = try set(nil, in: before)
        XCTAssertNil(try position(after))
        XCTAssertEqual(try Read.altitude(try XCTUnwrap(try Read.exif(after))), 1136.5)
        XCTAssertEqual(try Read.otherChunks(after), try Read.otherChunks(before))
    }

    // MARK: - What is refused

    func testWhatIsNotAPNGIsRefused() {
        XCTAssertThrowsError(try set(bixby, in: Fixture().bytes())) {
            XCTAssertEqual($0 as? ExifWriterError, .notThisFormat("a PNG"))
        }
    }

    func testAChunkCutShortIsRefused() {
        let whole = PNGFixture().bytes()
        XCTAssertThrowsError(try set(bixby, in: Array(whole[..<(whole.count - 5)]))) { error in
            guard case .malformed = error as? ExifWriterError else { return XCTFail("\(error)") }
        }
    }

    /// EXIF that is not a TIFF structure is refused and not written over.
    func testExifThatIsNotExifIsRefused() {
        let bytes = PNGFixture(exif: .holding([UInt8]("not EXIF at all".utf8))).bytes()
        XCTAssertThrowsError(try set(bixby, in: bytes))
    }

    // MARK: - A file on disk

    func testAFileIsReplacedWhole() throws {
        let scratch = try Scratch(PNGFixture().bytes(), extension: "png")
        XCTAssertTrue(try ExifGPS.setPosition(bixby, inFileAt: scratch.url, as: .png))
        assertSame(try ExifGPS.position(inFileAt: scratch.url, as: .png), bixby)
        XCTAssertTrue(try ExifGPS.setPosition(nil, inFileAt: scratch.url, as: .png))
        XCTAssertEqual([UInt8](try Data(contentsOf: scratch.url)), PNGFixture().bytes())
        XCTAssertFalse(try ExifGPS.setPosition(nil, inFileAt: scratch.url, as: .png))
    }
}
