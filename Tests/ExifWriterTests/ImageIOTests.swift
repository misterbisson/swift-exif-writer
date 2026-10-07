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

        /// **ImageIO writes a camera's position into a PNG twice**: in the
        /// EXIF, and again in the XMP packet beside it. Measured on macOS
        /// 27.0.1, where ExifTool lists both. It does not do so in a TIFF.
        var statesItInXMPToo: Bool { container == .png && camera }

        var type: String { container == .tiff ? "public.tiff" : "public.png" }
        var fileExtension: String { container == .tiff ? "tif" : "png" }
    }

    private let kinds = [
        Kind(name: "8-bit"), Kind(name: "16-bit", bits: 16), Kind(name: "LZW", compression: 5),
        Kind(name: "two pages", pages: 2), Kind(name: "camera's position", camera: true),
        Kind(name: "16-bit LZW with a camera's position", bits: 16, compression: 5, camera: true),
        Kind(name: "PNG", container: .png), Kind(name: "16-bit PNG", container: .png, bits: 16),
        Kind(name: "PNG with a camera's position", container: .png, camera: true),
        Kind(name: "PNG with no metadata", container: .png, bare: true),
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
        return scratch
    }

    /// What ImageIO reports about one page: its position, everything else,
    /// and the decoded picture.
    private struct Seen {
        var position: GPSPosition?
        var gps: [CFString: Any]
        var rest: NSDictionary
        var pixels: Data
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
        return Seen(position: position, gps: gps, rest: all as NSDictionary,
                    pixels: try XCTUnwrap(image.dataProvider?.data as Data?))
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
        for kind in kinds where !kind.statesItInXMPToo {
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

    /// **A position the file's XMP states is not this library's to change.**
    /// It writes the EXIF. Taken out of a PNG that ImageIO wrote a camera's
    /// position into, the EXIF has none, the XMP packet is the bytes it was,
    /// and ImageIO goes on reading the position from there. Whoever writes
    /// the XMP has to take it out of that too.
    func testAPositionInXMPIsLeftAsItWas() throws {
        for kind in kinds where kind.statesItInXMPToo {
            let scratch = try file(kind)
            func packet() throws -> [[UInt8]] {
                try Read.chunks([UInt8](try Data(contentsOf: scratch.url))).filter { $0.type == "iTXt" }.map(\.bytes)
            }
            let before = try packet()
            XCTAssertEqual(before.count, 1, kind.name)
            try ExifGPS.setPosition(nil, inFileAt: scratch.url, as: kind.container)
            XCTAssertNil(try ExifGPS.position(inFileAt: scratch.url, as: kind.container), kind.name)
            XCTAssertEqual(try packet(), before, kind.name)
        }
    }

    /// **ImageIO can rewrite a TIFF afterwards and the position survives**:
    /// an app that writes a rating into the file later, by copying it with
    /// new metadata, does not lose the place.
    func testThePositionSurvivesImageIOCopyingATIFF() throws {
        for kind in kinds where kind.pages == 1 && kind.container == .tiff {
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
        for kind in kinds where kind.container == .png && !kind.statesItInXMPToo {
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
            XCTAssertEqual(ExifTool.withoutPosition(after), ExifTool.withoutPosition(before), kind.name)
            XCTAssertNotNil(after["ImageDataHash"], kind.name)
        }
    }
}
#endif
