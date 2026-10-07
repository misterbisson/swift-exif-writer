import XCTest
@testable import ExifWriter

/// The XMP packet on its own: what it is read as, and what a write leaves
/// of it.
final class XMPPacketTests: XCTestCase {

    private let whitney = GPSPosition(latitude: 36.606111, longitude: -118.062778)!
    private let bixby = GPSPosition(latitude: 36.371389, longitude: -121.901944)!
    private let sydney = GPSPosition(latitude: -33.856784, longitude: 151.215297)!

    private func assertSame(_ found: GPSPosition?, _ wanted: GPSPosition, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(found?.latitude ?? .nan, wanted.latitude, accuracy: 1e-7, message, file: file, line: line)
        XCTAssertEqual(found?.longitude ?? .nan, wanted.longitude, accuracy: 1e-7, message, file: file, line: line)
    }

    private func said(_ bytes: [UInt8]?) -> String { bytes.map { String(decoding: $0, as: UTF8.self) } ?? "nil" }

    // MARK: Reading

    func testEachWritersPacketIsRead() throws {
        for style in XMPFixture.Style.allCases {
            assertSame(try XMPPacket.position(in: XMPFixture(style: style).bytes()), whitney, "\(style)")
            XCTAssertNil(try XMPPacket.position(in: XMPFixture(style: style).stating(nil).bytes()), "\(style)")
        }
    }

    func testTheNamespaceIsFoundUnderAnyPrefix() throws {
        for style in XMPFixture.Style.allCases {
            let packet = XMPFixture(style: style, prefix: "e").bytes()
            assertSame(try XMPPacket.position(in: packet), whitney, "\(style)")
            XCTAssertEqual(said(try XMPPacket.setting(sydney, in: packet)),
                           XMPFixture(style: style, prefix: "e").stating(sydney).text(), "\(style)")
        }
    }

    /// The forms a coordinate is found in: minutes with a fraction, minutes
    /// and seconds, and a bare number, with the hemisphere in the value or
    /// held apart.
    func testTheFormsACoordinateIsFoundIn() {
        XCTAssertEqual(XMPPacket.degrees("36,22.28334N", signedBy: nil, negative: "S") ?? .nan, 36.371389, accuracy: 1e-9)
        XCTAssertEqual(XMPPacket.degrees("121,54.11664W", signedBy: nil, negative: "W") ?? .nan, -121.901944, accuracy: 1e-9)
        XCTAssertEqual(XMPPacket.degrees("36,22,17N", signedBy: nil, negative: "S") ?? .nan, 36.371389, accuracy: 1e-6)
        XCTAssertEqual(XMPPacket.degrees("33,51,24.4S", signedBy: nil, negative: "S") ?? .nan, -33.856778, accuracy: 1e-6)
        XCTAssertEqual(XMPPacket.degrees("118.062778", signedBy: "W", negative: "W") ?? .nan, -118.062778, accuracy: 1e-9)
        XCTAssertEqual(XMPPacket.degrees("118.062778", signedBy: "E", negative: "W") ?? .nan, 118.062778, accuracy: 1e-9)
        XCTAssertEqual(XMPPacket.degrees("-118.062778", signedBy: nil, negative: "W") ?? .nan, -118.062778, accuracy: 1e-9)
        XCTAssertEqual(XMPPacket.degrees(" 36,22.5n ", signedBy: nil, negative: "S") ?? .nan, 36.375, accuracy: 1e-9)
        // The letter in the value is the one believed.
        XCTAssertEqual(XMPPacket.degrees("36,22.5S", signedBy: "N", negative: "S") ?? .nan, -36.375, accuracy: 1e-9)
        for nonsense in ["", "N", "north", "36,,5N", "36,-5N", "-36,5N", "1,2,3,4N", "36;22N"] {
            XCTAssertNil(XMPPacket.degrees(nonsense, signedBy: nil, negative: "S"), nonsense)
        }
    }

    func testABareNumberWithItsHemisphereApartIsRead() throws {
        var fixture = XMPFixture(style: .imageIO)
        fixture.latitude = "36.606111N"
        fixture.longitude = "118.062778W"
        // As ImageIO writes one given numbers: no letter in the value.
        let packet = [UInt8](fixture.text().replacingOccurrences(of: "111N<", with: "111<")
            .replacingOccurrences(of: "778W<", with: "778<").utf8)
        XCTAssertTrue(said(packet).contains("<exif:GPSLongitude>118.062778</exif:GPSLongitude>"))
        assertSame(try XMPPacket.position(in: packet), whitney)
        // Written back as XMP spells it, with the letter held apart made
        // to agree.
        XCTAssertEqual(said(try XMPPacket.setting(sydney, in: packet)),
                       XMPFixture(style: .imageIO).stating(sydney).text())
    }

    // MARK: Writing

    /// **Set, the packet is the same packet with other values in it**:
    /// every other byte where it was.
    func testSettingChangesTheValuesAndNothingElse() throws {
        for style in XMPFixture.Style.allCases {
            for place in [bixby, sydney] {
                let after = try XMPPacket.setting(place, in: XMPFixture(style: style).bytes())
                XCTAssertEqual(said(after), XMPFixture(style: style).stating(place).text(), "\(style)")
                assertSame(try XMPPacket.position(in: after ?? []), place, "\(style)")
            }
        }
    }

    /// **Taken out, the packet is as if it had never stated one.**
    func testTakingOutLeavesNoTraceOfIt() throws {
        for style in XMPFixture.Style.allCases {
            let after = try XMPPacket.setting(nil, in: XMPFixture(style: style).bytes())
            XCTAssertEqual(said(after), XMPFixture(style: style).stating(nil).text(), "\(style)")
        }
    }

    func testAPacketThatStatesNoPositionIsNotChanged() throws {
        for style in XMPFixture.Style.allCases {
            let packet = XMPFixture(style: style).stating(nil).bytes()
            XCTAssertNil(try XMPPacket.setting(bixby, in: packet), "\(style)")
            XCTAssertNil(try XMPPacket.setting(nil, in: packet), "\(style)")
        }
        XCTAssertNil(try XMPPacket.setting(bixby, in: [UInt8]("<x:xmpmeta>nothing much</x:xmpmeta>".utf8)))
        XCTAssertNil(try XMPPacket.setting(bixby, in: []))
    }

    /// Text that looks like a position and is not one: in a comment, in
    /// another property's value, and inside a structure further down.
    func testWhatOnlyLooksLikeAPositionIsLeft() throws {
        let packet = [UInt8]("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <!-- <exif:GPSLatitude>1,2.5N</exif:GPSLatitude> -->
              <rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:o="http://example.com/o/"
                o:note="exif:GPSLatitude=&quot;1,2.5N&quot;">
               <o:place rdf:parseType="Resource">
                <exif:GPSLatitude>1,2.5N</exif:GPSLatitude>
                <exif:GPSLongitude>3,4.5E</exif:GPSLongitude>
               </o:place>
               <o:text><![CDATA[<exif:GPSLongitude>3,4.5E</exif:GPSLongitude>]]></o:text>
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            """.utf8)
        XCTAssertEqual(try XMPPacket.statements(in: packet), [])
        XCTAssertNil(try XMPPacket.position(in: packet))
        XCTAssertNil(try XMPPacket.setting(bixby, in: packet))
    }

    /// A position held as something other than text cannot be written as
    /// it stands. It is refused, and can still be taken out.
    func testAPositionHeldAsMoreThanTextIsRefusedAndCanBeTakenOut() throws {
        func packet(_ latitude: String) -> [UInt8] {
            [UInt8]("""
                <x:xmpmeta xmlns:x="adobe:ns:meta/">
                 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                  <rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/">\(latitude)
                   <exif:GPSLongitude>3,4.5E</exif:GPSLongitude>
                  </rdf:Description>
                 </rdf:RDF>
                </x:xmpmeta>
                """.utf8)
        }
        let nested = "\n   <exif:GPSLatitude><rdf:Description><rdf:value>1,2.5N</rdf:value></rdf:Description></exif:GPSLatitude>"
        for odd in [nested, "\n   <exif:GPSLatitude/>", "\n   <exif:GPSLatitude rdf:resource=\"x\" />"] {
            XCTAssertNil(try XMPPacket.position(in: packet(odd)), odd)
            XCTAssertThrowsError(try XMPPacket.setting(bixby, in: packet(odd)), odd) {
                XCTAssertEqual($0 as? ExifWriterError,
                               .unsupported("XMP that states its position in a form this does not write"))
            }
            let cleared = try XMPPacket.setting(nil, in: packet(odd))
            XCTAssertEqual(said(cleared), said(packet("")).replacingOccurrences(
                of: "\n   <exif:GPSLongitude>3,4.5E</exif:GPSLongitude>", with: ""), odd)
        }
    }

    /// **What follows the packet's closing line is not the packet.** When
    /// ImageIO copies a PNG and the packet comes out shorter, it leaves the
    /// tail of the old one there, which is not XML. It is carried through
    /// as it was.
    func testWhatFollowsTheClosingLineIsNotRead() throws {
        let residue = "/exifEX:LensModel>\n      </rdf:Description>\n   </rdf:RDF>\n</x:xmpmeta>\n"
        for style in [XMPFixture.Style.lightroom, .exifTool] {
            let fixture = XMPFixture(style: style)
            let packet = [UInt8]((fixture.text() + residue).utf8)
            assertSame(try XMPPacket.position(in: packet), whitney, "\(style)")
            XCTAssertEqual(said(try XMPPacket.setting(sydney, in: packet)),
                           fixture.stating(sydney).text() + residue, "\(style)")
            XCTAssertEqual(said(try XMPPacket.setting(nil, in: packet)),
                           fixture.stating(nil).text() + residue, "\(style)")
        }
    }

    func testWhatCannotBeReadIsRefused() {
        var wide: [UInt8] = [0xFF, 0xFE]
        for byte in XMPFixture().bytes() { wide += [byte, 0] }
        XCTAssertThrowsError(try XMPPacket.setting(bixby, in: wide)) {
            XCTAssertEqual($0 as? ExifWriterError, .unsupported("an XMP packet that is not UTF-8"))
        }
        for broken in ["<x:xmpmeta><rdf:RDF>", "<x:xmpmeta a=>", "</x:xmpmeta>", "<x:xmpmeta a=\"1", "<!-- never closed"] {
            XCTAssertThrowsError(try XMPPacket.setting(bixby, in: [UInt8](broken.utf8)), broken) {
                XCTAssertEqual($0 as? ExifWriterError, .malformed("an XMP packet that is not XML"))
            }
        }
    }

    /// A coordinate a hair under a whole degree is the whole degree, and
    /// never 60 minutes.
    func testACoordinateAsItIsWritten() {
        func text(_ latitude: Double, _ longitude: Double) -> [String] {
            let position = GPSPosition(latitude: latitude, longitude: longitude)!
            return [XMPPacket.text(.latitude, position), XMPPacket.text(.longitude, position),
                    XMPPacket.text(.latitudeRef, position), XMPPacket.text(.longitudeRef, position)]
        }
        XCTAssertEqual(text(36.371389, -121.901944), ["36,22.283340N", "121,54.116640W", "N", "W"])
        XCTAssertEqual(text(-33.856784, 151.215297), ["33,51.407040S", "151,12.917820E", "S", "E"])
        XCTAssertEqual(text(0, 0), ["0,0.000000N", "0,0.000000E", "N", "E"])
        XCTAssertEqual(text(-0.5, 7.000001), ["0,30.000000S", "7,0.000060E", "S", "E"])
        XCTAssertEqual(text(36.99999999999, -179.99999999999), ["37,0.000000N", "180,0.000000W", "N", "W"])
        XCTAssertEqual(text(-90, 180), ["90,0.000000S", "180,0.000000E", "S", "E"])
        XCTAssertEqual(text(-89.9999999, -179.9999999).map(\.count), [13, 14, 1, 1], "the longest either is written at")
    }

    // MARK: Keeping a length

    func testAPacketIsFittedByItsPadding() throws {
        let packet = XMPFixture(style: .lightroom, padding: 10)
        // Longer: spaces go in before the wrapper closes.
        XCTAssertEqual(said(XMPPacket.fitted(packet.bytes(), to: packet.bytes().count + 5)),
                       XMPFixture(style: .lightroom, padding: 15).text())
        // Shorter: they come out of the same place, as far as there are
        // any.
        XCTAssertEqual(said(XMPPacket.fitted(packet.bytes(), to: packet.bytes().count - 10)),
                       XMPFixture(style: .lightroom, padding: 0).text())
        // The line break after the packet's last tag is white space too.
        XCTAssertNotNil(XMPPacket.fitted(packet.bytes(), to: packet.bytes().count - 11))
        XCTAssertNil(XMPPacket.fitted(packet.bytes(), to: packet.bytes().count - 12))
        XCTAssertEqual(XMPPacket.fitted(packet.bytes(), to: packet.bytes().count), packet.bytes())

        // With no wrapper the room is at the end, before any zeros a
        // writer ended the packet with.
        let bare = XMPFixture(style: .imageIO).bytes()
        XCTAssertEqual(XMPPacket.fitted(bare, to: bare.count + 3), bare + [0x20, 0x20, 0x20])
        XCTAssertEqual(XMPPacket.fitted(bare + [0, 0], to: bare.count + 5), bare + [0x20, 0x20, 0x20, 0, 0])
        XCTAssertEqual(XMPPacket.fitted(bare + [0x20, 0x20, 0x20], to: bare.count + 1), bare + [0x20])
        XCTAssertNil(XMPPacket.fitted(bare, to: bare.count - 2))
    }

    /// The room a moved packet is given covers the longest position.
    func testTheSlackCoversTheLongestPosition() throws {
        let longest = GPSPosition(latitude: -89.9999999, longitude: -179.9999999)!
        for style in XMPFixture.Style.allCases {
            var fixture = XMPFixture(style: style)
            fixture.latitude = "1,2.5N"
            fixture.longitude = "3,4.5E"
            let packet = fixture.bytes()
            let grown = try XCTUnwrap(try XMPPacket.setting(longest, in: packet))
            XCTAssertEqual(grown.count - packet.count, try XMPPacket.slack(in: packet), "\(style)")
            XCTAssertEqual(try XMPPacket.slack(in: grown), 0, "\(style)")
        }
    }
}
