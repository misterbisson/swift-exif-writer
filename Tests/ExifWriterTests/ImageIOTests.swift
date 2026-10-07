#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import XCTest
@testable import ExifWriter

/// **What Apple's reader makes of a file this library wrote.** ImageIO is
/// what Photos, Finder and Preview read a photograph with, and it shares no
/// code with this library.
///
/// The files are TIFFs and PNGs ImageIO wrote itself, which are laid out as
/// a real writer lays them out and not as the hand-built fixtures are.
final class ImageIOTests: XCTestCase {

    private let bixby = GPSPosition(latitude: 36.371389, longitude: -121.901944)!
    private let sydney = GPSPosition(latitude: -33.856784, longitude: 151.215297)!

    private struct Kind {
        let name: String
        var container = ImageContainer.tiff
        var bits = 8
        var compression = 1
        var pages = 1
        var camera = false
        /// Written with no properties at all, so the file has no EXIF.
        var bare = false
        /// The file's XMP packet states the camera's position too, in a
        /// packet ImageIO laid out. Not for a PNG, where ImageIO puts it
        /// there unasked (`statesItInXMPToo`).
        var inPacket = false
        /// The packet's padding is taken away, so a longer position does
        /// not fit where the packet lies. ImageIO pads a TIFF's packet.
        var packetHasNoRoom = false

        /// **ImageIO writes a camera's position into a PNG twice**: in the
        /// EXIF, and again in the XMP packet beside it. Measured on macOS
        /// 27.0.1, where ExifTool lists both. It does not do so in a TIFF.
        var statesItInXMPToo: Bool { container == .png && camera }

        /// One of the HEICs beside the tests, used as it is. A HEIC is not
        /// made here, because a CI runner cannot be counted on to encode one.
        var drawn: String?

        var type: String {
            switch container {
            case .tiff: "public.tiff"
            case .png: "public.png"
            case .heic: "public.heic"
            }
        }
        var fileExtension: String { container.fileExtension }
    }

    private let kinds = [
        Kind(name: "8-bit"), Kind(name: "16-bit", bits: 16), Kind(name: "LZW", compression: 5),
        Kind(name: "two pages", pages: 2), Kind(name: "camera's position", camera: true),
        Kind(name: "16-bit LZW with a camera's position", bits: 16, compression: 5, camera: true),
        Kind(name: "PNG", container: .png), Kind(name: "16-bit PNG", container: .png, bits: 16),
        Kind(name: "PNG with a camera's position", container: .png, camera: true),
        Kind(name: "PNG with no metadata", container: .png, bare: true),
        Kind(name: "HEIC", container: .heic, drawn: "drawn"),
        Kind(name: "HEIC with a camera's position", container: .heic, camera: true, drawn: "drawn-camera"),
        Kind(name: "TIFF with the position in its packet too", camera: true, inPacket: true),
        Kind(name: "TIFF with the position in a packet with no room", camera: true, inPacket: true,
             packetHasNoRoom: true),
        Kind(name: "HEIC with the position in its packet too", container: .heic, camera: true, inPacket: true,
             drawn: "drawn-xmp"),
    ]

    private func image(bits: Int, seed: Int) throws -> CGImage {
        let width = 48, height = 32, bytes = bits / 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4 * bytes)
        for index in pixels.indices { pixels[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index / 7 &+ seed) }
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
            | (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
            bytesPerRow: width * 4 * bytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }

    private func file(_ kind: Kind) throws -> Scratch {
        if let drawn = kind.drawn {
            let bytes = Sample.drawn(drawn)
            XCTAssertFalse(bytes.isEmpty, "the fixture \(drawn).heic is missing")
            return try Scratch(bytes, extension: kind.fileExtension)
        }
        let scratch = try Scratch([], extension: kind.fileExtension)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            scratch.url as CFURL, kind.type as CFString, kind.pages, nil))
        var properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: kind.compression,
                                             kCGImagePropertyTIFFMake: "Fixture",
                                             kCGImagePropertyTIFFXResolution: 300,
                                             kCGImagePropertyTIFFYResolution: 300],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "50mm",
                                             kCGImagePropertyExifDateTimeOriginal: "2026:10:06 12:00:00"],
        ]
        if kind.camera {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 36.606111, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 118.062778, kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSAltitude: 1136.5, kCGImagePropertyGPSAltitudeRef: 0,
                kCGImagePropertyGPSImgDirection: 271.5, kCGImagePropertyGPSImgDirectionRef: "T",
            ]
        }
        for page in 0..<kind.pages {
            CGImageDestinationAddImage(destination, try image(bits: kind.bits, seed: page * 13),
                                       kind.bare ? nil : properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return kind.inPacket ? try statingItInItsPacket(scratch, kind) : scratch
    }

    /// **The same file with the camera's position in its XMP packet.**
    /// ImageIO will not write `exif:GPSLatitude` into a packet, so it is
    /// asked for the two values under a namespace one letter off, and the
    /// letter is then put right in the file's bytes. The same length, so
    /// nothing in the file moves. `drawn-xmp.heic` was made the same way.
    private func statingItInItsPacket(_ scratch: Scratch, _ kind: Kind) throws -> Scratch {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(scratch.url as CFURL, nil))
        let packet = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(
            packet, "http://ns.adobe.com/exiq/1.0/" as CFString, "exiq" as CFString, nil))
        CGImageMetadataSetValueWithPath(packet, nil, "exiq:GPSLatitude" as CFString, "36,36.366660N" as CFString)
        CGImageMetadataSetValueWithPath(packet, nil, "exiq:GPSLongitude" as CFString, "118,3.766680W" as CFString)
        // Something only the packet says, so a test can ask ImageIO for it
        // and know the packet is still one it reads.
        CGImageMetadataSetValueWithPath(packet, nil, "xmp:CreatorTool" as CFString, "Fixture" as CFString)
        let staged = try Scratch([], extension: kind.fileExtension)
        let copy = try XCTUnwrap(CGImageDestinationCreateWithURL(staged.url as CFURL, kind.type as CFString, 1, nil))
        let options: [CFString: Any] = [kCGImageDestinationMetadata: packet, kCGImageDestinationMergeMetadata: true]
        XCTAssertTrue(CGImageDestinationCopyImageSource(copy, source, options as CFDictionary, nil), kind.name)

        var bytes = [UInt8](try Data(contentsOf: staged.url))
        let wrong = [UInt8]("exiq".utf8)
        for index in bytes.indices.dropLast(3) where Array(bytes[index..<index + 4]) == wrong {
            bytes[index + 3] = UInt8(ascii: "f")
        }
        // A packet that already named the real namespace now names it
        // twice, which is not XML, and ImageIO answers that by reading none
        // of the packet. The second naming is blanked, at the same length.
        let naming = [UInt8](#"xmlns:exif="http://ns.adobe.com/exif/1.0/""#.utf8)
        let named = bytes.indices.dropLast(naming.count).filter {
            bytes[$0] == naming[0] && Array(bytes[$0..<$0 + naming.count]) == naming
        }
        XCTAssertLessThanOrEqual(named.count, 2, kind.name)
        if named.count == 2 {
            bytes.replaceSubrange(named[1]..<named[1] + naming.count,
                                  with: [UInt8](repeating: UInt8(ascii: " "), count: naming.count))
        }
        if kind.packetHasNoRoom {
            // The packet is written again where it lies without its
            // padding, and the directory told its new length.
            let tiff = try TIFFStructure(ArrayStore(bytes: bytes))
            let root = try tiff.directory(at: tiff.first)
            let index = try XCTUnwrap(root.index(of: TIFFStructure.xmpPacket))
            let held = try XCTUnwrap(try Read.packet(bytes))
            var tight = held.bytes
            while let shorter = XMPPacket.fitted(tight, to: tight.count - 1) { tight = shorter }
            XCTAssertLessThan(tight.count, held.bytes.count, "the packet had no padding to take away")
            bytes.replaceSubrange(held.offset..<held.offset + tight.count, with: tight)
            bytes.replaceSubrange(root.countOffset(of: index)..<root.countOffset(of: index) + 4,
                                  with: tiff.bytes(UInt32(tight.count)))
        }
        let out = try Scratch(bytes, extension: kind.fileExtension)
        XCTAssertEqual(try see(out.url).creator, "Fixture", "ImageIO does not read the fixture's packet: \(kind.name)")
        XCTAssertNotNil(try ExifGPS.position(inFileAt: out.url, as: kind.container), kind.name)
        return out
    }

    /// What ImageIO reports about one page: its position, everything else,
    /// and the decoded picture.
    private struct Seen {
        var position: GPSPosition?
        var gps: [CFString: Any]
        var rest: NSDictionary
        var pixels: Data
        /// What the XMP packet says wrote the file, which nothing else in
        /// the file says: nil where ImageIO does not read the packet.
        var creator: String?
    }

    private func see(_ url: URL, page: Int = 0) throws -> Seen {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
        var all = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, page, nil) as? [CFString: Any])
        let gps = all[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        all[kCGImagePropertyGPSDictionary] = nil
        var position: GPSPosition?
        if let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
           let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue {
            let south = gps[kCGImagePropertyGPSLatitudeRef] as? String == "S"
            let west = gps[kCGImagePropertyGPSLongitudeRef] as? String == "W"
            position = GPSPosition(latitude: south ? -latitude : latitude, longitude: west ? -longitude : longitude)
        }
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, page, nil))
        let creator = CGImageSourceCopyMetadataAtIndex(source, page, nil).flatMap {
            CGImageMetadataCopyStringValueWithPath($0, nil, "xmp:CreatorTool" as CFString) as String?
        }
        return Seen(position: position, gps: gps, rest: all as NSDictionary,
                    pixels: try XCTUnwrap(image.dataProvider?.data as Data?), creator: creator)
    }

    /// **ImageIO gives a position back to a ten-thousandth of a minute**,
    /// about 18 cm, cut and not rounded. Measured on macOS 27.0.1 on files
    /// ExifTool wrote as well as on this library's, in TIFF, PNG, HEIC and
    /// JPEG alike, so it is the reader's own grain and not the writer's.
    private static let imageIOGrain = 1.0 / 600_000

    private func assertSame(_ found: GPSPosition?, _ wanted: GPSPosition, _ message: String,
                            accuracy: Double = imageIOGrain,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(found?.latitude ?? .nan, wanted.latitude, accuracy: accuracy, message,
                       file: file, line: line)
        XCTAssertEqual(found?.longitude ?? .nan, wanted.longitude, accuracy: accuracy, message,
                       file: file, line: line)
    }

    // MARK: -

    /// **ImageIO reads the position this library wrote, and the same
    /// picture and the same everything else as before.**
    func testImageIOReadsThePositionAndNothingElseChanged() throws {
        for kind in kinds {
            let scratch = try file(kind)
            let before = try (0..<kind.pages).map { try see(scratch.url, page: $0) }
            XCTAssertEqual(before[0].position != nil, kind.camera, kind.name)

            for place in [bixby, sydney] {
                try ExifGPS.setPosition(place, inFileAt: scratch.url, as: kind.container)
                let after = try (0..<kind.pages).map { try see(scratch.url, page: $0) }
                assertSame(after[0].position, place, kind.name)
                for page in 0..<kind.pages {
                    XCTAssertEqual(after[page].pixels, before[page].pixels, "\(kind.name), page \(page)")
                    XCTAssertEqual(after[page].rest, before[page].rest, "\(kind.name), page \(page)")
                }
            }
        }
    }

    /// What else the camera's block said is still there under a new
    /// position.
    func testTheRestOfACamerasBlockIsKept() throws {
        for kind in kinds where kind.camera {
            let scratch = try file(kind)
            try ExifGPS.setPosition(sydney, inFileAt: scratch.url, as: kind.container)
            let gps = try see(scratch.url).gps
            XCTAssertEqual((gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue, 1136.5, kind.name)
            XCTAssertEqual((gps[kCGImagePropertyGPSImgDirection] as? NSNumber)?.doubleValue, 271.5, kind.name)
            XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef] as? String, "S", kind.name)
            XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "E", kind.name)
        }
    }

    /// **Taken out, ImageIO reads no position**, and the same picture and
    /// the same everything else.
    func testImageIOReadsNoPositionOnceItIsTakenOut() throws {
        for kind in kinds {
            let scratch = try file(kind)
            let before = try see(scratch.url)
            if !kind.camera { try ExifGPS.setPosition(bixby, inFileAt: scratch.url, as: kind.container) }
            try ExifGPS.setPosition(nil, inFileAt: scratch.url, as: kind.container)
            let after = try see(scratch.url)
            XCTAssertNil(after.position, kind.name)
            XCTAssertEqual(after.pixels, before.pixels, kind.name)
            XCTAssertEqual(after.rest, before.rest, kind.name)
            XCTAssertEqual(after.gps[kCGImagePropertyGPSAltitude] != nil, kind.camera, kind.name)
        }
    }

    /// **A packet ImageIO wrote is changed with the EXIF, and ImageIO still
    /// reads it.** The packet's position is the one set, what else the
    /// packet says is still read, and the picture and every other property
    /// are what they were.
    ///
    /// Each file is taken two ways: a position that is longer than the
    /// camera's first, and a shorter one first. ImageIO pads a TIFF's
    /// packet, so both fit where the packet lies. One TIFF has its padding
    /// taken away, and its packet moves to the end of the file for the
    /// longer position.
    func testImageIOStillReadsAPacketThisChanged() throws {
        let near = GPSPosition(latitude: 5.5, longitude: 8.25)!
        XCTAssertTrue(kinds.contains { $0.inPacket || $0.statesItInXMPToo })
        for kind in kinds where kind.inPacket || kind.statesItInXMPToo {
            for places in [[sydney, near, nil], [near, sydney, nil]] {
                let scratch = try file(kind)
                let before = try see(scratch.url)
                let lay = kind.container == .tiff ? try Read.packet([UInt8](try Data(contentsOf: scratch.url))) : nil
                for place in places {
                    try ExifGPS.setPosition(place, inFileAt: scratch.url, as: kind.container)
                    let after = try see(scratch.url)
                    let message = "\(kind.name), \(place.map { "\($0.latitude)" } ?? "taken out")"
                    // Both ways are taken: a packet with no room moves for
                    // the longer position, and any other stays.
                    if let lay, place == places[0] {
                        let now = try XCTUnwrap(try Read.packet([UInt8](try Data(contentsOf: scratch.url))))
                        XCTAssertEqual(now.offset != lay.offset, kind.packetHasNoRoom && place == sydney, message)
                    }
                    XCTAssertEqual(after.creator, before.creator, "the packet is not read as it was: \(message)")
                    XCTAssertEqual(after.pixels, before.pixels, message)
                    XCTAssertEqual(after.rest, before.rest, message)
                    let packet = try packet(scratch.url, kind)
                    if let place {
                        assertSame(after.position, place, message)
                        assertSame(try XMPPacket.position(in: packet), place, message, accuracy: 1e-7)
                    } else {
                        XCTAssertNil(after.position, message)
                        XCTAssertEqual(try XMPPacket.statements(in: packet), [], message)
                    }
                }
                // A packet the position was taken out of states none, and
                // is not given one again: the EXIF is.
                try ExifGPS.setPosition(bixby, inFileAt: scratch.url, as: kind.container)
                assertSame(try see(scratch.url).position, bixby, kind.name)
                XCTAssertEqual(try XMPPacket.statements(in: try packet(scratch.url, kind)), [], kind.name)
                XCTAssertEqual(try see(scratch.url).creator, before.creator, kind.name)
            }
        }
    }

    /// The file's XMP packet, found the way each kind of file holds one.
    private func packet(_ url: URL, _ kind: Kind) throws -> [UInt8] {
        let bytes = [UInt8](try Data(contentsOf: url))
        switch kind.container {
        case .tiff: return try XCTUnwrap(try Read.packet(bytes)).bytes
        case .png: return try XCTUnwrap(try Read.packet(png: bytes))
        case .heic:
            let packets = try Read.items(bytes).values.filter { $0.starts(with: [UInt8]("<x:xmpmeta".utf8)) }
            XCTAssertEqual(packets.count, 1, kind.name)
            return try XCTUnwrap(packets.first)
        }
    }

    /// **ImageIO can rewrite a TIFF or a HEIC afterwards and the position
    /// survives**: an app that writes a rating into the file later, by
    /// copying it with new metadata, does not lose the place.
    func testThePositionSurvivesImageIOCopyingTheFile() throws {
        for kind in kinds where kind.pages == 1 && kind.container != .png {
            let scratch = try file(kind)
            try ExifGPS.setPosition(bixby, inFileAt: scratch.url, as: kind.container)
            let pixels = try see(scratch.url).pixels
            let copy = try copied(scratch, kind)
            let after = try see(copy.url)
            assertSame(after.position, bixby, kind.name)
            XCTAssertEqual(after.pixels, pixels, kind.name)
            // And this library still reads and moves it there.
            assertSame(try ExifGPS.position(inFileAt: copy.url, as: kind.container), bixby, kind.name)
            try ExifGPS.setPosition(sydney, inFileAt: copy.url, as: kind.container)
            assertSame(try see(copy.url).position, sydney, kind.name)
        }
    }

    /// **ImageIO's copy does not keep a PNG's EXIF as it was**, whoever
    /// wrote it: measured on macOS 27.0.1, a position ExifTool wrote came
    /// out of the copy with its latitude and no longitude. That is not
    /// asserted here, because it is a fault and may be mended. What is
    /// asserted is the way round it: set the position after the copy, and
    /// it is there.
    func testAfterImageIOCopiesAPNGThePositionIsSetAgain() throws {
        for kind in kinds where kind.container == .png {
            let scratch = try file(kind)
            try ExifGPS.setPosition(bixby, inFileAt: scratch.url, as: kind.container)
            let pixels = try see(scratch.url).pixels
            let copy = try copied(scratch, kind)
            try ExifGPS.setPosition(bixby, inFileAt: copy.url, as: kind.container)
            let after = try see(copy.url)
            assertSame(after.position, bixby, kind.name)
            XCTAssertEqual(after.pixels, pixels, kind.name)
        }
    }

    /// **What ImageIO leaves after a PNG's packet is gone once the file is
    /// written.** Measured on macOS 27.0.1: its copy of a PNG, with a rating
    /// merged in, writes a shorter packet into a chunk of the old length,
    /// and the end of the old packet stays after the closing line, where
    /// ExifTool reads tags out of it. That it does so is not asserted, since
    /// it is a fault and may be mended: where nothing is left, there is
    /// nothing to try.
    func testWhatImageIOLeavesAfterAPNGsPacketIsCut() throws {
        func left(_ url: URL) throws -> [UInt8] {
            let packet = try XCTUnwrap(try Read.packet(png: [UInt8](try Data(contentsOf: url))))
            return Array(packet.dropFirst(try XMPPacket.trimmed(packet)?.count ?? packet.count))
        }
        func rating(_ url: URL) throws -> String? {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap {
                CGImageMetadataCopyStringValueWithPath($0, nil, "xmp:Rating" as CFString) as String?
            }
        }
        var tried = 0
        for kind in kinds where kind.container == .png && !kind.bare {
            for place in [bixby, nil] {
                let copy = try copied(try file(kind), kind)
                guard !(try left(copy.url)).isEmpty else { continue }
                tried += 1
                let message = "\(kind.name), \(place == nil ? "taken out" : "set")"
                let before = try see(copy.url)
                if ExifTool.path != nil {
                    XCTAssertTrue(try ExifTool.faults(copy.url).contains { $0.contains("out of scope") },
                                  "ExifTool no longer reads what was left: \(message)")
                }
                XCTAssertTrue(try ExifGPS.setPosition(place, inFileAt: copy.url, as: .png), message)
                XCTAssertEqual(try left(copy.url), [], message)
                let after = try see(copy.url)
                XCTAssertEqual(after.pixels, before.pixels, message)
                XCTAssertEqual(after.rest, before.rest, message)
                XCTAssertEqual(try rating(copy.url), "4", "ImageIO no longer reads the packet: \(message)")
                if let place { assertSame(after.position, place, message) } else { XCTAssertNil(after.position, message) }
                if ExifTool.path != nil {
                    XCTAssertFalse(try ExifTool.faults(copy.url).contains { $0.contains("out of scope") }, message)
                }
            }
        }
        try XCTSkipIf(tried == 0, "ImageIO left nothing after a PNG's packet on this system")
    }

    /// The file copied by ImageIO with a rating merged into its metadata,
    /// which is how an app writes one without re-encoding.
    private func copied(_ scratch: Scratch, _ kind: Kind) throws -> Scratch {
        let copy = try Scratch([], extension: kind.fileExtension)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(scratch.url as CFURL, nil))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            copy.url as CFURL, kind.type as CFString, 1, nil))
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, 4 as CFNumber)
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata,
                                        kCGImageDestinationMergeMetadata: true]
        XCTAssertTrue(CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil),
                      kind.name)
        return copy
    }

    /// ExifTool and ImageIO agree about a file this library wrote, on files
    /// a real writer laid out.
    func testExifToolAgreesOnFilesImageIOWrote() throws {
        for kind in kinds {
            let scratch = try file(kind)
            let before = try ExifTool.everything(scratch.url)
            try ExifGPS.setPosition(sydney, inFileAt: scratch.url, as: kind.container)
            let after = try ExifTool.everything(scratch.url)
            assertSame(try ExifTool.position(scratch.url), sydney, kind.name, accuracy: 1e-7)
            XCTAssertEqual(ExifTool.differing(ExifTool.withoutPosition(after),
                                              ExifTool.withoutPosition(before)), [], kind.name)
            XCTAssertNotNil(after["ImageDataHash"], kind.name)
        }
    }
}
#endif
