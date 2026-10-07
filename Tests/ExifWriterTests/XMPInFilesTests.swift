import XCTest
@testable import ExifWriter

/// **A position the file's XMP packet states is changed with the EXIF's**,
/// in each kind of file, and a packet that states none is the bytes it was.
final class XMPInFilesTests: XCTestCase {

    private let whitney = GPSPosition(latitude: 36.606111, longitude: -118.062778)!
    private let bixby = GPSPosition(latitude: 36.371389, longitude: -121.901944)!
    private let sydney = GPSPosition(latitude: -33.856784, longitude: 151.215297)!
    /// As long as a position is written.
    private let longest = GPSPosition(latitude: -89.9999999, longitude: -179.9999999)!
    private let camera = Fixture.Block.camera(latitude: 36.606111, longitude: -118.062778, altitude: 1136.5)

    private func assertSame(_ found: GPSPosition?, _ wanted: GPSPosition, _ message: String = "",
                            accuracy: Double = 1e-7, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(found?.latitude ?? .nan, wanted.latitude, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(found?.longitude ?? .nan, wanted.longitude, accuracy: accuracy, message, file: file, line: line)
    }

    /// The hand-built camera's block keeps a hundredth of a second, as a
    /// camera does, which is a little coarser than the packet beside it.
    private let cameras = 1e-6

    private func set(_ position: GPSPosition?, _ bytes: [UInt8], _ container: ImageContainer) throws -> [UInt8] {
        [UInt8](try ExifGPS.settingPosition(position, in: Data(bytes), as: container))
    }

    private func said(_ bytes: [UInt8]?) -> String { bytes.map { String(decoding: $0, as: UTF8.self) } ?? "nil" }

    // MARK: - TIFF

    /// **A packet with room is changed where it lies**: the same place in
    /// the file, the same length, the difference taken out of its padding.
    func testATIFFsPacketWithRoomIsChangedWhereItLies() throws {
        let packet = XMPFixture(style: .lightroom, padding: 40)
        let before = Fixture(block: camera, packet: packet.bytes()).bytes()
        let was = try XCTUnwrap(try Read.packet(before))

        var bytes = before
        for place in [sydney, longest, bixby] {
            bytes = try set(place, bytes, .tiff)
            let now = try XCTUnwrap(try Read.packet(bytes))
            XCTAssertEqual(now.offset, was.offset)
            let wanted = packet.stating(place)
            var padded = wanted
            padded.padding = 40 - (wanted.bytes().count - packet.bytes().count)
            XCTAssertEqual(said(now.bytes), padded.text())
            assertSame(try ExifGPS.position(in: Data(bytes), as: .tiff), place)
            XCTAssertEqual(try Read.pixels(bytes), Fixture().pixels)
            XCTAssertEqual(try Read.altitude(bytes), 1136.5)
            // Nothing before the packet moved or changed.
            XCTAssertEqual(Array(bytes[8..<was.offset]), Array(before[8..<was.offset]))
        }
    }

    /// **A packet with no room is written again at the end**, with room,
    /// and the one it replaces is left where it was. After that a write
    /// fits, and the file does not grow.
    func testATIFFsPacketWithNoRoomMovesOnceAndThenStays() throws {
        var packet = XMPFixture(style: .imageIO)
        packet.latitude = "1,2.5N"
        packet.longitude = "3,4.5E"
        for blockLast in [false, true] {
            let before = Fixture(block: camera, blockLast: blockLast, packet: packet.bytes()).bytes()
            let was = try XCTUnwrap(try Read.packet(before))

            let moved = try set(bixby, before, .tiff)
            let now = try XCTUnwrap(try Read.packet(moved))
            XCTAssertGreaterThanOrEqual(now.offset, before.count, "the packet is past everything that was there")
            XCTAssertEqual(Array(moved[was.offset..<was.offset + was.bytes.count]), was.bytes,
                           "the old packet is the bytes it was")
            assertSame(try XMPPacket.position(in: now.bytes), bixby)
            assertSame(try ExifGPS.position(in: Data(moved), as: .tiff), bixby)
            XCTAssertEqual(try Read.pixels(moved), Fixture().pixels)
            XCTAssertEqual(try Read.altitude(moved), 1136.5)
            // The packet with the trailing room taken off is the fixture's.
            XCTAssertEqual(said(now.bytes).trimmingCharacters(in: .whitespacesAndNewlines),
                           packet.stating(bixby).text().trimmingCharacters(in: .whitespacesAndNewlines))

            var bytes = moved
            for place in [longest, sydney, whitney] {
                bytes = try set(place, bytes, .tiff)
                XCTAssertEqual(bytes.count, moved.count, "a later write grew the file")
                let later = try XCTUnwrap(try Read.packet(bytes))
                XCTAssertEqual(later.offset, now.offset)
                XCTAssertEqual(later.bytes.count, now.bytes.count)
                assertSame(try XMPPacket.position(in: later.bytes), place)
                assertSame(try ExifGPS.position(in: Data(bytes), as: .tiff), place)
            }
        }
    }

    func testTakingAPositionOutOfATIFFTakesItOutOfThePacket() throws {
        for style in XMPFixture.Style.allCases {
            let packet = XMPFixture(style: style)
            let before = Fixture(block: camera, packet: packet.bytes()).bytes()
            let was = try XCTUnwrap(try Read.packet(before))
            let after = try set(nil, before, .tiff)
            let now = try XCTUnwrap(try Read.packet(after))
            XCTAssertNil(try ExifGPS.position(in: Data(after), as: .tiff), "\(style)")
            XCTAssertEqual(now.offset, was.offset, "\(style)")
            // The same length, the difference given to its padding.
            XCTAssertEqual(now.bytes, XMPPacket.fitted(packet.stating(nil).bytes(), to: was.bytes.count), "\(style)")
            XCTAssertEqual(try Read.altitude(after), 1136.5, "\(style)")
            XCTAssertEqual(try Read.pixels(after), Fixture().pixels, "\(style)")
        }
    }

    /// A file that states its position only in its packet: it is read from
    /// there, and setting one writes the EXIF as well.
    func testAFileThatStatesItOnlyInItsPacket() throws {
        for style in XMPFixture.Style.allCases {
            let packet = XMPFixture(style: style, padding: 0)
            for (name, container, before) in [
                ("TIFF", ImageContainer.tiff, Fixture(packet: packet.bytes()).bytes()),
                ("PNG", .png, PNGFixture(packet: packet.bytes()).bytes()),
                ("HEIC", .heic, HEICFixture(packet: packet.bytes()).bytes()),
            ] {
                let message = "\(name), \(style)"
                assertSame(try ExifGPS.position(in: Data(before), as: container), whitney, message)
                let placed = try set(sydney, before, container)
                assertSame(try ExifGPS.position(in: Data(placed), as: container), sydney, message)
                assertSame(try exifAlone(placed, container), sydney, message)
                assertSame(try XMPPacket.position(in: try XCTUnwrap(try self.packet(placed, container))), sydney, message)

                let cleared = try set(nil, placed, container)
                XCTAssertNil(try ExifGPS.position(in: Data(cleared), as: container), message)
                XCTAssertNil(try XMPPacket.position(in: try XCTUnwrap(try self.packet(cleared, container))), message)
                XCTAssertEqual(try set(nil, cleared, container), cleared, message)

                // Taken out with no EXIF to take it out of.
                let only = try set(nil, before, container)
                XCTAssertNil(try ExifGPS.position(in: Data(only), as: container), message)
            }
        }
    }

    /// **A packet that states no position is the bytes it was**, and so is
    /// everything else that is not the EXIF.
    func testAPacketThatStatesNoneIsLeftAsItWas() throws {
        for style in XMPFixture.Style.allCases {
            let packet = XMPFixture(style: style).stating(nil).bytes()
            for (name, container, before) in [
                ("TIFF", ImageContainer.tiff, Fixture(block: camera, packet: packet).bytes()),
                ("PNG", .png, PNGFixture(exif: .holding(Fixture(block: camera).bytes()), packet: packet).bytes()),
                ("HEIC", .heic, HEICFixture(exif: Fixture(block: camera).bytes(), packet: packet).bytes()),
            ] {
                for place in [sydney, nil] {
                    let after = try set(place, before, container)
                    XCTAssertEqual(try self.packet(after, container), packet, "\(name), \(style)")
                    XCTAssertNil(try XMPPacket.position(in: packet))
                }
            }
        }
    }

    /// The file edited where it stands comes out as the bytes worked out in
    /// memory do.
    func testAFileEditedWhereItStandsMatchesTheBytes() throws {
        var tight = XMPFixture(style: .imageIO)
        tight.latitude = "1,2.5N"
        tight.longitude = "3,4.5E"
        let files: [(String, ImageContainer, [UInt8])] = [
            ("TIFF with room", .tiff, Fixture(block: camera, packet: XMPFixture().bytes()).bytes()),
            ("TIFF with none", .tiff, Fixture(block: camera, packet: tight.bytes()).bytes()),
            ("TIFF with none, block last", .tiff, Fixture(block: camera, blockLast: true, packet: tight.bytes()).bytes()),
            ("TIFF, packet only", .tiff, Fixture(little: false, packet: XMPFixture(style: .exifTool).bytes()).bytes()),
            ("PNG", .png, PNGFixture(packet: XMPFixture().bytes()).bytes()),
            ("HEIC", .heic, HEICFixture(packet: tight.bytes()).bytes()),
        ]
        for (name, container, before) in files {
            let scratch = try Scratch(before, extension: container.fileExtension)
            var bytes = before
            for place in [bixby, longest, nil, sydney] {
                bytes = try set(place, bytes, container)
                try ExifGPS.setPosition(place, inFileAt: scratch.url, as: container)
                XCTAssertEqual([UInt8](try Data(contentsOf: scratch.url)), bytes, name)
                let read = try ExifGPS.position(inFileAt: scratch.url, as: container)
                if let place { assertSame(read, place, name) } else { XCTAssertNil(read, name) }
            }
        }
    }

    /// **The two places a file states its position are read apart**, for a
    /// caller that has to know which said it. Here they are made to
    /// disagree, as a file somebody else wrote may.
    func testTheEXIFAndThePacketAreReadApart() throws {
        let elsewhere = XMPFixture(style: .exifTool).stating(sydney).bytes()
        let none = XMPFixture(style: .exifTool).stating(nil).bytes()
        let held = Fixture(block: camera).bytes()
        let files: [(String, ImageContainer, ([UInt8]?, Bool) -> [UInt8])] = [
            ("TIFF", .tiff, { packet, block in Fixture(block: block ? self.camera : .none, packet: packet).bytes() }),
            ("PNG", .png, { packet, block in PNGFixture(exif: block ? .holding(held) : .none, packet: packet).bytes() }),
            ("HEIC", .heic, { packet, block in
                HEICFixture(exif: block ? held : Fixture().bytes(), packet: packet ?? HEICFixture.notes).bytes()
            }),
        ]
        for (name, container, file) in files {
            let both = try ExifGPS.positions(in: Data(file(elsewhere, true)), as: container)
            assertSame(both.exif, whitney, name, accuracy: cameras)
            assertSame(both.xmp, sydney, name)
            assertSame(both.position, whitney, "the EXIF's is the file's, \(name)", accuracy: cameras)

            let packetOnly = try ExifGPS.positions(in: Data(file(elsewhere, false)), as: container)
            XCTAssertNil(packetOnly.exif, name)
            assertSame(packetOnly.xmp, sydney, name)
            assertSame(packetOnly.position, sydney, name)

            let blockOnly = try ExifGPS.positions(in: Data(file(none, true)), as: container)
            assertSame(blockOnly.exif, whitney, name, accuracy: cameras)
            XCTAssertNil(blockOnly.xmp, name)

            XCTAssertEqual(try ExifGPS.positions(in: Data(file(nil, false)), as: container),
                           StatedPositions(exif: nil, xmp: nil), name)

            // From a file as from its bytes, and a write brings the two
            // into step.
            let scratch = try Scratch(file(elsewhere, true), extension: container.fileExtension)
            XCTAssertEqual(try ExifGPS.positions(inFileAt: scratch.url, as: container), both, name)
            try ExifGPS.setPosition(bixby, inFileAt: scratch.url, as: container)
            let after = try ExifGPS.positions(inFileAt: scratch.url, as: container)
            assertSame(after.exif, bixby, name)
            assertSame(after.xmp, bixby, name)
        }
    }

    // MARK: - PNG

    /// **A PNG as Lightroom exports one**: the position in the packet and
    /// no EXIF. Set, it has both. Taken out again, it is the same file with
    /// a packet that never stated one.
    func testAPNGThatStatesItOnlyInItsPacket() throws {
        let packet = XMPFixture(style: .lightroom, padding: 17)
        let before = PNGFixture(packet: packet.bytes()).bytes()
        let placed = try set(bixby, before, .png)
        XCTAssertEqual(said(try Read.packet(png: placed)), packet.stating(bixby).text())
        assertSame(try exifAlone(placed, .png), bixby)
        XCTAssertEqual(try Read.chunksBesideMetadata(placed), try Read.chunksBesideMetadata(before))
        XCTAssertEqual(try Read.chunks(placed).map(\.type),
                       ["IHDR", "pHYs", "tEXt", "iTXt", "eXIf", "IDAT", "IDAT", "IEND"])

        let cleared = try set(nil, placed, .png)
        XCTAssertEqual(cleared, PNGFixture(packet: packet.stating(nil).bytes()).bytes())
    }

    func testAPNGWhoseEXIFAndPacketBothStateIt() throws {
        for style in XMPFixture.Style.allCases {
            let packet = XMPFixture(style: style)
            let before = PNGFixture(exif: .holding(Fixture(block: camera).bytes()), packet: packet.bytes()).bytes()
            let placed = try set(sydney, before, .png)
            XCTAssertEqual(said(try Read.packet(png: placed)), packet.stating(sydney).text(), "\(style)")
            assertSame(try exifAlone(placed, .png), sydney, "\(style)")
            XCTAssertEqual(try Read.chunksBesideMetadata(placed), try Read.chunksBesideMetadata(before), "\(style)")
            XCTAssertEqual(try set(sydney, placed, .png), placed, "\(style)")
        }
    }

    /// **What follows a PNG's packet is cut off on any write.** ImageIO
    /// leaves the end of an older packet there when its copy comes out
    /// shorter, and here that end holds a position the packet no longer
    /// states.
    func testWhatFollowsAPNGsPacketIsCutOnAnyWrite() throws {
        let residue = [UInt8]("""
              <exif:GPSLatitude>36,36.366660N</exif:GPSLatitude>
                 <exif:GPSLongitude>118,3.766680W</exif:GPSLongitude>
              </rdf:Description>
           </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="r"?>
        """.utf8)
        for style in [XMPFixture.Style.lightroom, .exifTool] {
            let stating = XMPFixture(style: style)
            let silent = stating.stating(nil)
            let camera = Fixture(block: self.camera).bytes()

            // The packet states a position: it is changed, and the rest goes.
            let placed = PNGFixture(packet: stating.bytes() + residue).bytes()
            let moved = try set(sydney, placed, .png)
            XCTAssertEqual(said(try Read.packet(png: moved)), stating.stating(sydney).text(), "\(style)")
            XCTAssertEqual(try Read.chunksBesideMetadata(moved), try Read.chunksBesideMetadata(placed), "\(style)")
            XCTAssertEqual(said(try Read.packet(png: try set(nil, placed, .png))), silent.text(), "\(style)")

            // It states none: the packet is the bytes it was, without them.
            let unplaced = PNGFixture(exif: .holding(camera), packet: silent.bytes() + residue).bytes()
            for place in [sydney, nil] {
                let after = try set(place, unplaced, .png)
                XCTAssertEqual(said(try Read.packet(png: after)), silent.text(), "\(style)")
                XCTAssertEqual(try Read.chunksBesideMetadata(after), try Read.chunksBesideMetadata(unplaced), "\(style)")
            }

            // No position anywhere, and still a change, once.
            let bare = PNGFixture(packet: silent.bytes() + residue).bytes()
            let scratch = try Scratch(bare, extension: "png")
            XCTAssertTrue(try ExifGPS.setPosition(nil, inFileAt: scratch.url, as: .png), "\(style)")
            let cut = [UInt8](try Data(contentsOf: scratch.url))
            XCTAssertEqual(cut, PNGFixture(packet: silent.bytes()).bytes(), "\(style)")
            XCTAssertFalse(try ExifGPS.setPosition(nil, inFileAt: scratch.url, as: .png), "\(style)")

            // White space after the closing line is nothing to cut.
            let spaced = PNGFixture(exif: .holding(camera), packet: silent.bytes() + [0x0A]).bytes()
            XCTAssertEqual(try Read.packet(png: try set(sydney, spaced, .png)), silent.bytes() + [0x0A], "\(style)")
            XCTAssertEqual(try set(nil, PNGFixture(packet: silent.bytes() + [0x0A]).bytes(), .png),
                           PNGFixture(packet: silent.bytes() + [0x0A]).bytes(), "\(style)")
        }
    }

    /// Only a PNG's. ImageIO has not been seen to leave anything after a
    /// TIFF's or a HEIC's packet, and theirs come through as they were.
    func testWhatFollowsATIFFsOrAHEICsPacketIsLeft() throws {
        let residue = [UInt8]("\n   </rdf:RDF>\n</x:xmpmeta>\n".utf8)
        let packet = XMPFixture(style: .exifTool).stating(nil).bytes() + residue
        let camera = Fixture(block: self.camera).bytes()
        for (name, container, before) in [
            ("TIFF", ImageContainer.tiff, Fixture(block: self.camera, packet: packet).bytes()),
            ("HEIC", .heic, HEICFixture(exif: camera, packet: packet).bytes()),
        ] {
            XCTAssertEqual(try self.packet(try set(sydney, before, container), container), packet, name)
        }
    }

    /// A packet that is compressed cannot be read, so what it states is not
    /// known, and the file is refused and not changed.
    func testAPNGWhosePacketIsCompressedIsRefused() throws {
        let before = PNGFixture(packet: [0x78, 0x9C, 0x03, 0x00], packetCompressed: true).bytes()
        XCTAssertThrowsError(try set(bixby, before, .png)) {
            XCTAssertEqual($0 as? ExifWriterError, .unsupported("XMP that is compressed"))
        }
        let scratch = try Scratch(before, extension: "png")
        XCTAssertThrowsError(try ExifGPS.setPosition(bixby, inFileAt: scratch.url, as: .png))
        XCTAssertEqual([UInt8](try Data(contentsOf: scratch.url)), before)
    }

    // MARK: - HEIC

    private var layouts: [(name: String, fixture: HEICFixture)] {
        var out: [(String, HEICFixture)] = [("as Apple lays one out", HEICFixture())]
        out.append(("EXIF after the picture", HEICFixture(exifLast: true)))
        out.append(("the item list last", HEICFixture(metaLast: true)))
        out.append(("locations of version 0", HEICFixture(version: 0)))
        out.append(("locations of version 2", HEICFixture(version: 2)))
        out.append(("offsets from a base", HEICFixture(based: true)))
        out.append(("wide offsets", HEICFixture(wide: true)))
        out.append(("a data box with a long length", HEICFixture(largeData: true)))
        out.append(("everything at once", HEICFixture(exifLast: true, metaLast: true, version: 2, based: true,
                                                      wide: true, largeData: true)))
        return out
    }

    /// **Both items change and the picture between them does not**, in
    /// every layout the offsets come in.
    func testAHEICsPacketAndEXIFBothChange() throws {
        for (name, layout) in layouts {
            for style in XMPFixture.Style.allCases {
                let packet = XMPFixture(style: style)
                var fixture = layout
                fixture.exif = Fixture(block: camera).bytes()
                fixture.packet = packet.bytes()
                let before = fixture.bytes()
                let message = "\(name), \(style)"

                var bytes = before
                for place in [sydney, longest, nil] {
                    bytes = try set(place, bytes, .heic)
                    let items = try Read.items(bytes)
                    XCTAssertEqual(items[1], HEICFixture.picture, message)
                    XCTAssertEqual(said(items[3]), packet.stating(place).text(), message)
                    XCTAssertEqual(try Read.boxes(bytes).map(\.size).reduce(0, +), bytes.count, message)
                    if let place {
                        assertSame(try exifAlone(bytes, .heic), place, message)
                    } else {
                        XCTAssertNil(try ExifGPS.position(in: Data(bytes), as: .heic), message)
                    }
                }
                // Set again, it is the size it was when first set.
                XCTAssertEqual(try set(sydney, try set(bixby, before, .heic), .heic).count,
                               try set(sydney, before, .heic).count, message)
            }
        }
    }

    /// A HEIC with no EXIF is still refused, whatever its packet states,
    /// and nothing of it is changed. Its packet's position can be read, and
    /// taken out.
    func testAHEICWithNoEXIFIsStillRefused() throws {
        let packet = XMPFixture(style: .imageIO)
        let before = HEICFixture(noExif: true, packet: packet.bytes()).bytes()
        assertSame(try ExifGPS.position(in: Data(before), as: .heic), whitney)
        XCTAssertThrowsError(try set(bixby, before, .heic)) {
            XCTAssertEqual($0 as? ExifWriterError, .unsupported("a HEIC with no EXIF"))
        }
        let scratch = try Scratch(before, extension: "heic")
        XCTAssertThrowsError(try ExifGPS.setPosition(bixby, inFileAt: scratch.url, as: .heic))
        XCTAssertEqual([UInt8](try Data(contentsOf: scratch.url)), before)

        let cleared = try set(nil, before, .heic)
        XCTAssertEqual(said(try Read.items(cleared)[3]), packet.stating(nil).text())
        XCTAssertEqual(try Read.items(cleared)[1], HEICFixture.picture)
    }

    // MARK: - Two edits as one

    /// Two edits made as one leave what the two made in turn leave, and the
    /// store the second is planned over reads as the first leaves it.
    func testTwoEditsMadeAsOneAreTheTwoMadeInTurn() throws {
        let bytes = (0..<40).map { UInt8($0) }
        let firsts = [
            ByteEdit(),
            ByteEdit(append: [101, 102, 103], patches: [.init(offset: 5, bytes: [9, 9])]),
            ByteEdit(truncate: 36, append: [101, 102, 103, 104], patches: [.init(offset: 34, bytes: [7, 7, 7])]),
            ByteEdit(patches: [.init(offset: 38, bytes: [5, 5])]),
        ]
        for first in firsts {
            let between = first.applied(to: bytes)
            let store = EditedStore(base: ArrayStore(bytes: bytes), edit: first)
            XCTAssertEqual(store.count, between.count)
            XCTAssertEqual(try store.read(0, between.count), between)
            for start in stride(from: 0, to: between.count - 3, by: 3) {
                XCTAssertEqual(try store.read(start, 3), Array(between[start..<start + 3]))
            }
            XCTAssertThrowsError(try store.read(between.count - 1, 2))

            for cut in [nil, between.count, between.count - 1, between.count - 3, 37, 36, 20] as [Int?] {
                let second = ByteEdit(truncate: cut, append: [201, 202], patches: [.init(offset: 2, bytes: [8])])
                XCTAssertEqual(first.then(second, over: bytes.count).applied(to: bytes),
                               second.applied(to: between), "\(first), then cut at \(String(describing: cut))")
            }
        }
    }

    // MARK: -

    /// The position the EXIF states, with the packet left out of it.
    private func exifAlone(_ bytes: [UInt8], _ container: ImageContainer) throws -> GPSPosition? {
        switch container {
        case .tiff: return try GPSBlock.position(in: ArrayStore(bytes: bytes))
        case .png: return try Read.exif(bytes).flatMap { try GPSBlock.position(in: ArrayStore(bytes: $0)) }
        case .heic:
            // Past the four bytes that give the prefix's length, and the
            // prefix.
            guard let item = try Read.items(bytes)[2] else { return nil }
            return try GPSBlock.position(in: ArrayStore(bytes: Array(item.dropFirst(4 + Int(item[3])))))
        }
    }

    private func packet(_ bytes: [UInt8], _ container: ImageContainer) throws -> [UInt8]? {
        switch container {
        case .tiff: return try Read.packet(bytes)?.bytes
        case .png: return try Read.packet(png: bytes)
        case .heic: return try Read.items(bytes)[3]
        }
    }
}
