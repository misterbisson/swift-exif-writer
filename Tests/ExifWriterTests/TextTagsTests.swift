import XCTest
@testable import ExifWriter

/// The text tags of a TIFF, on files built by hand in both byte orders, so
/// each test knows where every byte is and can say which ones changed.
final class TextTagsTests: XCTestCase {

    private let scanner = "EPSON Perfection V600"
    private let camera = "Nikon FE2"
    private let bixby = GPSPosition(latitude: 36.371389, longitude: -121.901944)!

    private func set(_ text: [ExifTag: String], removing: Set<ExifTag> = [], in bytes: [UInt8]) throws -> [UInt8] {
        [UInt8](try ExifText.setting(text, removing: removing, in: Data(bytes), as: .tiff))
    }

    private func text(_ tag: ExifTag, _ bytes: [UInt8]) throws -> String? {
        try ExifText.text(of: tag, in: Data(bytes), as: .tiff)
    }

    /// Where the bytes of `before` differ from the same stretch of `after`.
    private func changed(_ before: [UInt8], _ after: [UInt8]) -> Set<Int> {
        Set((0..<min(before.count, after.count)).filter { before[$0] != after[$0] })
    }

    private var bothOrders: [Bool] { [true, false] }

    // MARK: - A tag the file lacks

    /// **The first directory gets one entry longer, so it is written again
    /// at the end, and only the header's pointer to it changes in what was
    /// there.**
    func testATagTheFirstDirectoryLacksIsAdded() throws {
        for little in bothOrders {
            let before = Fixture(little: little).bytes()
            XCTAssertNil(try text(.model, before))
            let after = try set([.model: camera], in: before)
            XCTAssertEqual(try text(.model, after), camera)
            XCTAssertEqual(changed(before, after).subtracting(4..<8), [], "little \(little)")
            XCTAssertEqual(Array(after[..<before.count].dropFirst(8)), Array(before.dropFirst(8)))
            XCTAssertEqual(try Read.pixels(after), Fixture(little: little).pixels)
            let tags = try Read.firstDirectory(after).entries.map(\.tag)
            XCTAssertEqual(tags, tags.sorted(), "the entries are in the order of their tags")
        }
    }

    /// **A file with no EXIF directory gets one**, and the first directory
    /// a pointer to it.
    func testAFileWithNoExifDirectoryGetsOne() throws {
        for little in bothOrders {
            let before = Fixture(little: little).bytes()
            XCTAssertNil(try Read.exifDirectory(before))
            let after = try set([.offsetTimeOriginal: "+02:00", .dateTimeOriginal: "2019:07:04 22:30:00"], in: before)
            XCTAssertEqual(try text(.offsetTimeOriginal, after), "+02:00")
            XCTAssertEqual(try text(.dateTimeOriginal, after), "2019:07:04 22:30:00")
            XCTAssertEqual(try Read.exifDirectory(after)?.entries.map(\.tag), [0x9000, 0x9003, 0x9011],
                           "the new directory says its version too")
            XCTAssertEqual(changed(before, after).subtracting(4..<8), [], "little \(little)")
            XCTAssertEqual(try Read.pixels(after), Fixture(little: little).pixels)
        }
    }

    /// **An EXIF directory that lacks the tag is written again at the end
    /// with it, and only the first directory's four bytes that point at it
    /// change.** The first directory itself stays where it is.
    func testATagTheExifDirectoryLacksIsAdded() throws {
        for little in bothOrders {
            let fixture = Fixture(little: little, exif: [0x9003: "2001:01:01 01:01:01"])
            let before = fixture.bytes()
            let after = try set([.offsetTimeOriginal: "+02:00"], in: before)
            XCTAssertEqual(try text(.offsetTimeOriginal, after), "+02:00")
            XCTAssertEqual(try text(.dateTimeOriginal, after), "2001:01:01 01:01:01", "what was there is kept")
            XCTAssertEqual(changed(before, after).count <= 4, true, "little \(little)")
            XCTAssertEqual(Array(after[..<8]), Array(before[..<8]), "the first directory did not move")
        }
    }

    // MARK: - A tag the file has

    /// **A value no longer than the one it replaces is written where that
    /// one lies.** Nothing is added to the file, and what changes is the
    /// value's own bytes and the four that say how long it is.
    func testAValueThatFitsIsWrittenWhereTheOldOneLies() throws {
        for little in bothOrders {
            let before = Fixture(little: little, text: [0x0110: scanner]).bytes()
            XCTAssertEqual(try text(.model, before), scanner)
            let after = try set([.model: camera], in: before)
            XCTAssertEqual(try text(.model, after), camera)
            XCTAssertEqual(after.count, before.count)
            XCTAssertEqual(changed(before, after).count <= scanner.utf8.count + 1 + 4, true, "little \(little)")
            XCTAssertEqual(Array(after[..<8]), Array(before[..<8]))
        }
    }

    /// **A date is always the same length, so changing one changes those
    /// bytes and nothing else**, however often.
    func testADateIsChangedInPlaceEveryTime() throws {
        for little in bothOrders {
            let before = Fixture(little: little, exif: [0x9003: "2001:01:01 01:01:01"]).bytes()
            var bytes = before
            for date in ["2019:07:04 22:30:00", "1999:12:31 23:59:58", "2019:07:04 22:30:00"] {
                bytes = try set([.dateTimeOriginal: date], in: bytes)
                XCTAssertEqual(try text(.dateTimeOriginal, bytes), date)
                XCTAssertEqual(bytes.count, before.count, "little \(little)")
            }
            XCTAssertEqual(changed(before, bytes).count <= 19, true)
        }
    }

    /// **A longer value goes at the end, and the eight bytes of its entry
    /// that say how long it is and where are all that change.**
    func testALongerValueGoesAtTheEnd() throws {
        for little in bothOrders {
            let before = Fixture(little: little, text: [0x0110: camera]).bytes()
            let after = try set([.model: scanner], in: before)
            XCTAssertEqual(try text(.model, after), scanner)
            XCTAssertEqual(changed(before, after).count <= 8, true, "little \(little)")
            XCTAssertEqual(after.count, before.count + scanner.utf8.count + 1)
        }
    }

    /// **Two tags that keep one value in the same bytes are two tags.** A
    /// value written over there would change both, so it goes at the end.
    func testAValueAnotherTagSharesIsNotWrittenOver() throws {
        for little in bothOrders {
            let before = Fixture(little: little, text: [0x010F: scanner, 0x0110: scanner], textShared: true).bytes()
            let first = try Read.firstDirectory(before)
            XCTAssertEqual(first.entry(0x010F)?.value, first.entry(0x0110)?.value,
                           "the fixture must keep the two in the same bytes")
            let after = try set([.model: camera], in: before)
            XCTAssertEqual(try text(.model, after), camera)
            XCTAssertEqual(try text(.make, after), scanner, "little \(little)")
        }
    }

    /// Text short enough to sit in the entry's own four bytes sits there,
    /// and text that was there and no longer fits goes at the end.
    func testTextThatFitsInTheEntryIsKeptThere() throws {
        for little in bothOrders {
            let before = Fixture(little: little, text: [0x0110: "M6"]).bytes()
            XCTAssertEqual(try text(.model, before), "M6")
            let short = try set([.model: "FE2"], in: before)
            XCTAssertEqual(try text(.model, short), "FE2")
            XCTAssertEqual(short.count, before.count)
            let long = try set([.model: camera], in: short)
            XCTAssertEqual(try text(.model, long), camera)
            let back = try set([.model: "M6"], in: long)
            XCTAssertEqual(try text(.model, back), "M6")
            XCTAssertEqual(back.count, long.count)
        }
    }

    /// Setting what the file already says changes nothing, and says so.
    func testSettingWhatIsThereChangesNothing() throws {
        let before = Fixture(text: [0x0110: camera], exif: [0x9011: "+02:00"]).bytes()
        XCTAssertEqual(try set([.model: camera, .offsetTimeOriginal: "+02:00"], removing: [.make, .lensModel],
                               in: before), before)
        let file = try Scratch(before, extension: "tif")
        XCTAssertFalse(try ExifText.set([.model: camera], removing: [.make], inFileAt: file.url, as: .tiff))
        XCTAssertTrue(try ExifText.set([.model: scanner], inFileAt: file.url, as: .tiff))
        XCTAssertEqual(try ExifText.text(of: .model, inFileAt: file.url, as: .tiff), scanner)
    }

    // MARK: - Taking one out

    /// **The directory gets shorter where it stands**, the file keeps its
    /// length, and every other tag reads as it did.
    func testATagIsTakenOut() throws {
        for little in bothOrders {
            let fixture = Fixture(little: little, text: [0x010F: "EPSON", 0x0110: scanner],
                                  exif: [0x9003: "2001:01:01 01:01:01", 0x9011: "+09:00"])
            let before = fixture.bytes()
            let after = try set([:], removing: [.make, .offsetTimeOriginal], in: before)
            XCTAssertNil(try text(.make, after))
            XCTAssertNil(try text(.offsetTimeOriginal, after))
            XCTAssertEqual(try text(.model, after), scanner)
            XCTAssertEqual(try text(.dateTimeOriginal, after), "2001:01:01 01:01:01")
            XCTAssertEqual(after.count, before.count, "little \(little)")
            XCTAssertEqual(Array(after[..<8]), Array(before[..<8]))
            XCTAssertEqual(try Read.pixels(after), fixture.pixels)
            let was = try Read.firstDirectory(before).entries.count
            let shorter = try Read.firstDirectory(after)
            XCTAssertEqual(shorter.entries.count, was - 1)
            // The room the entry left is zeroed, and is not an entry's worth
            // of what used to be the directory's end.
            let room = shorter.offset + shorter.length
            XCTAssertEqual(Array(after[room..<room + 12]), [UInt8](repeating: 0, count: 12), "little \(little)")
        }
    }

    /// A tag named to be set and to be taken out is set.
    func testATagNamedBothWaysIsSet() throws {
        let before = Fixture(text: [0x0110: scanner]).bytes()
        XCTAssertEqual(try text(.model, try set([.model: camera], removing: [.model], in: before)), camera)
    }

    /// One write that adds to one directory, replaces in the other and
    /// takes out of both.
    func testSeveralChangesAtOnce() throws {
        for little in bothOrders {
            let fixture = Fixture(little: little, text: [0x010F: "EPSON", 0x0110: scanner],
                                  exif: [0x9003: "2001:01:01 01:01:01", 0x9004: "2002:02:02 02:02:02",
                                         0x9011: "+09:00", 0xA433: "Old", 0xA434: "Old Lens"])
            let after = try set([.model: camera, .dateTimeOriginal: "2019:07:04 22:30:00",
                                 .dateTimeDigitized: "2020:09:13 05:26:40", .offsetTimeOriginal: "+02:00",
                                 .lensModel: "Nikkor 50mm f/1.8", .software: "Anchorframe"],
                                removing: [.make, .lensMake], in: fixture.bytes())
            XCTAssertEqual(try text(.model, after), camera)
            XCTAssertEqual(try text(.software, after), "Anchorframe")
            XCTAssertNil(try text(.make, after))
            XCTAssertEqual(try text(.dateTimeOriginal, after), "2019:07:04 22:30:00")
            XCTAssertEqual(try text(.dateTimeDigitized, after), "2020:09:13 05:26:40")
            XCTAssertEqual(try text(.offsetTimeOriginal, after), "+02:00")
            XCTAssertEqual(try text(.lensModel, after), "Nikkor 50mm f/1.8")
            XCTAssertNil(try text(.lensMake, after))
            XCTAssertEqual(try Read.pixels(after), fixture.pixels, "little \(little)")
        }
    }

    /// Text that is not ASCII is written as UTF-8 and read back the same.
    func testTextThatIsNotASCIIComesBack() throws {
        let name = "Pentax 28–70mm ƒ/4"
        let after = try set([.lensModel: name], in: Fixture().bytes())
        XCTAssertEqual(try text(.lensModel, after), name)
    }

    // MARK: - The position

    /// **A GPS block that was the last thing in the file still is**, so the
    /// next position costs nothing, and what the block said beside the
    /// position is still there.
    func testTheBlockStaysTheLastThing() throws {
        for little in bothOrders {
            let fixture = Fixture(little: little,
                                  block: .camera(latitude: 36.606111, longitude: -118.062778, altitude: 1136.5),
                                  blockLast: true)
            let before = fixture.bytes()
            let named = try set([.model: camera, .offsetTimeOriginal: "+02:00"], in: before)
            XCTAssertEqual(try text(.model, named), camera)
            let position = try ExifGPS.position(in: Data(named), as: .tiff)
            XCTAssertEqual(position?.latitude ?? 0, 36.606111, accuracy: 1e-5, "little \(little)")
            XCTAssertEqual(position?.longitude ?? 0, -118.062778, accuracy: 1e-5)
            XCTAssertEqual(try Read.altitude(named) ?? 0, 1136.5, accuracy: 0.01)

            // Moving it cuts the block off and writes it in the same place,
            // the first time as every time after.
            let moved = [UInt8](try ExifGPS.settingPosition(bixby, in: Data(named), as: .tiff))
            XCTAssertEqual(moved.count, named.count, "the block was still the last thing, little \(little)")
            let again = [UInt8](try ExifGPS.settingPosition(
                GPSPosition(latitude: -33.86, longitude: 151.21), in: Data(moved), as: .tiff))
            XCTAssertEqual(again.count, moved.count, "a second position did not grow the file")
            XCTAssertEqual(try text(.model, again), camera)
            XCTAssertEqual(try text(.offsetTimeOriginal, again), "+02:00")
            XCTAssertEqual(try Read.altitude(again) ?? 0, 1136.5, accuracy: 0.01)
        }
    }

    /// The other order: a position this library wrote, then text. The
    /// position is as it was, and moving it afterwards still costs nothing.
    func testTextAfterAPositionThisWrote() throws {
        for little in bothOrders {
            let placed = [UInt8](try ExifGPS.settingPosition(bixby, in: Data(Fixture(little: little).bytes()), as: .tiff))
            let named = try set([.model: camera, .dateTimeOriginal: "2019:07:04 22:30:00"], in: placed)
            let position = try ExifGPS.position(in: Data(named), as: .tiff)
            XCTAssertEqual(position?.latitude ?? 0, bixby.latitude, accuracy: 1e-9, "little \(little)")
            XCTAssertEqual(position?.longitude ?? 0, bixby.longitude, accuracy: 1e-9)

            let moved = [UInt8](try ExifGPS.settingPosition(
                GPSPosition(latitude: -33.86, longitude: 151.21), in: Data(named), as: .tiff))
            XCTAssertEqual(moved.count, named.count, "the block was still the last thing")
            XCTAssertEqual(try text(.model, moved), camera)
        }
    }

    /// A block that is not the last thing is left where it is, and what is
    /// new goes after everything.
    func testABlockInTheMiddleIsNotMoved() throws {
        let fixture = Fixture(block: .camera(latitude: 36.606111, longitude: -118.062778, altitude: 1136.5))
        let before = fixture.bytes()
        let after = try set([.model: camera], in: before)
        XCTAssertEqual(Array(after[8..<before.count]), Array(before[8...]), "nothing that was there moved")
        XCTAssertEqual(try ExifGPS.position(in: Data(after), as: .tiff)?.latitude ?? 0, 36.606111, accuracy: 1e-5)
    }

    // MARK: - Refused

    func testWhatIsRefused() throws {
        let tiff = Fixture().bytes()
        XCTAssertThrowsError(try set([.lensSpecification: "50"], in: tiff), "a tag that is not text")
        XCTAssertThrowsError(try set([.model: "a\u{0}b"], in: tiff), "a zero byte")
        XCTAssertThrowsError(try ExifText.setting([.model: camera], in: Data(PNGFixture().bytes()), as: .png))
        XCTAssertThrowsError(try ExifText.text(of: .model, in: Data(PNGFixture().bytes()), as: .png))
        XCTAssertThrowsError(try ExifText.setting([.model: camera], in: Data(Sample.drawn("drawn")), as: .heic))
        // A tag that is not text can still be taken out, and is not read as text.
        XCTAssertEqual(try set([:], removing: [.lensSpecification], in: tiff), tiff)
    }
}
