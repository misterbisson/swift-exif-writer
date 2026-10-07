#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import XCTest
@testable import ExifWriter

/// **What Apple's reader makes of text this library wrote**, on TIFFs
/// ImageIO wrote itself, which are laid out as a real writer lays them out.
///
/// And the use this was written for: a file ImageIO's own copy has just
/// rewritten, which does not say what the copy was handed.
final class TextImageIOTests: XCTestCase {

    private struct Kind {
        let name: String
        var bits = 8
        var compression = 1
        var pages = 1
        /// The file states a scanner, a lens and its times already.
        var stated = false
        var position = false
    }

    private let kinds = [
        Kind(name: "8 bit, stating nothing"),
        Kind(name: "8 bit, stating all of it", stated: true),
        Kind(name: "16 bit LZW, stating all of it and a position", bits: 16, compression: 5, stated: true,
             position: true),
        Kind(name: "two pages, stating all of it", pages: 2, stated: true),
        Kind(name: "16 bit, a position and nothing else", bits: 16, position: true),
    ]

    private let text: [ExifTag: String] = [
        .model: "Nikon FE2", .dateTimeOriginal: "2019:07:04 22:30:00",
        .dateTimeDigitized: "2020:09:13 05:26:40", .offsetTimeOriginal: "+02:00",
        .lensModel: "Nikkor 50mm f/1.8",
    ]

    private func image(bits: Int, seed: Int) throws -> CGImage {
        let width = 12, height = 9
        let bytesPerPixel = bits / 8 * 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for index in pixels.indices { pixels[index] = UInt8(truncatingIfNeeded: index &* 31 &+ seed) }
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
            | (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
            bytesPerRow: width * bytesPerPixel, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }

    private func file(_ kind: Kind) throws -> Scratch {
        let scratch = try Scratch([], extension: "tif")
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(scratch.url as CFURL, "public.tiff" as CFString, kind.pages, nil))
        var properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: kind.compression] as [CFString: Any],
        ]
        if kind.stated {
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFCompression: kind.compression,
                kCGImagePropertyTIFFMake: "EPSON", kCGImagePropertyTIFFModel: "EPSON Perfection V600",
            ] as [CFString: Any]
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: "2001:01:01 01:01:01",
                kCGImagePropertyExifDateTimeDigitized: "2002:02:02 02:02:02",
                kCGImagePropertyExifOffsetTimeOriginal: "+09:00",
                kCGImagePropertyExifLensMake: "Old", kCGImagePropertyExifLensModel: "Old Lens",
            ] as [CFString: Any]
        }
        if kind.position {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 36.606111, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 118.062778, kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSAltitude: 1136.5,
            ] as [CFString: Any]
        }
        for page in 0..<kind.pages {
            CGImageDestinationAddImage(destination, try image(bits: kind.bits, seed: page * 97),
                                       properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return scratch
    }

    /// What ImageIO reads of one page: its text, its position, its picture
    /// decoded, and everything else it reports.
    private struct Seen {
        var text: [String: String] = [:]
        var position: [String: String] = [:]
        var pixels = Data()
        var rest = NSDictionary()
        var pages = 0
    }

    private func see(_ url: URL, page: Int = 0) throws -> Seen {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        var properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, page, nil) as? [CFString: Any])
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var seen = Seen()
        for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel] {
            seen.text[key as String] = tiff.removeValue(forKey: key) as? String
        }
        for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
                    kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifLensMake,
                    kCGImagePropertyExifLensModel] {
            seen.text[key as String] = exif.removeValue(forKey: key) as? String
        }
        // A directory this library started says its version.
        exif.removeValue(forKey: kCGImagePropertyExifVersion)
        for (key, value) in properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:] {
            seen.position[key as String] = "\(value)"
        }
        properties[kCGImagePropertyTIFFDictionary] = tiff.isEmpty ? nil : tiff
        properties[kCGImagePropertyExifDictionary] = exif.isEmpty ? nil : exif
        properties[kCGImagePropertyGPSDictionary] = nil
        seen.rest = properties as NSDictionary
        seen.pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, page, nil)?.dataProvider?.data) as Data
        seen.pages = CGImageSourceGetCount(source)
        return seen
    }

    private func assertText(_ seen: Seen, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(seen.text[kCGImagePropertyTIFFModel as String], "Nikon FE2", name, file: file, line: line)
        XCTAssertNil(seen.text[kCGImagePropertyTIFFMake as String], name, file: file, line: line)
        XCTAssertEqual(seen.text[kCGImagePropertyExifDateTimeOriginal as String], "2019:07:04 22:30:00", name,
                       file: file, line: line)
        XCTAssertEqual(seen.text[kCGImagePropertyExifDateTimeDigitized as String], "2020:09:13 05:26:40", name,
                       file: file, line: line)
        XCTAssertEqual(seen.text[kCGImagePropertyExifOffsetTimeOriginal as String], "+02:00", name,
                       file: file, line: line)
        XCTAssertEqual(seen.text[kCGImagePropertyExifLensModel as String], "Nikkor 50mm f/1.8", name,
                       file: file, line: line)
        XCTAssertNil(seen.text[kCGImagePropertyExifLensMake as String], name, file: file, line: line)
    }

    /// **ImageIO reads the text, and the same picture, the same position
    /// and the same everything else**, on every page.
    func testImageIOReadsTheTextAndNothingElseChanged() throws {
        for kind in kinds {
            let scratch = try file(kind)
            let before = try (0..<kind.pages).map { try see(scratch.url, page: $0) }
            XCTAssertTrue(try ExifText.set(text, removing: [.make, .lensMake], inFileAt: scratch.url, as: .tiff))
            let after = try (0..<kind.pages).map { try see(scratch.url, page: $0) }

            assertText(after[0], kind.name)
            XCTAssertEqual(after[0].pages, kind.pages, kind.name)
            for page in 0..<kind.pages {
                XCTAssertEqual(after[page].pixels, before[page].pixels, "page \(page), \(kind.name)")
                XCTAssertEqual(after[page].position, before[page].position, "page \(page), \(kind.name)")
                XCTAssertEqual(after[page].rest, before[page].rest, "page \(page), \(kind.name)")
            }
            // A later page keeps the text it had.
            if kind.pages > 1 { XCTAssertEqual(after[1].text, before[1].text, kind.name) }
        }
    }

    /// **The use this was written for.** ImageIO's copy is handed a camera,
    /// a lens and a time, and writes a file that does not state them all.
    /// The text and the position are then set in that file, and ImageIO
    /// reads every one, the same picture, and the packet the copy wrote.
    ///
    /// What the copy got wrong is not asserted: that is Apple's to change,
    /// and this has to hold either way.
    func testWhatImageIOsCopyLeftIsSetRight() throws {
        let sydney = GPSPosition(latitude: -33.856784, longitude: 151.215297)!
        for kind in kinds {
            let scratch = try file(kind)
            let before = try see(scratch.url)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(scratch.url as CFURL, nil))
            let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
                .flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
            XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(
                metadata, "http://example.com/ns/1.0/" as CFString, "example" as CFString, nil))
            XCTAssertTrue(CGImageMetadataSetValueWithPath(
                metadata, nil, "example:RollID" as CFString, "a roll" as CFString))
            for (dictionary, key, value) in [
                (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFModel, "Nikon FE2"),
                (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, "2019:07:04 22:30:00"),
                (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized, "2020:09:13 05:26:40"),
                (kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeOriginal, "+02:00"),
                (kCGImagePropertyExifDictionary, kCGImagePropertyExifLensModel, "Nikkor 50mm f/1.8"),
            ] {
                CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, value as CFString)
            }
            CGImageMetadataRemoveTagWithPath(metadata, nil, "tiff:Make" as CFString)
            CGImageMetadataRemoveTagWithPath(metadata, nil, "exifEX:LensMake" as CFString)

            let copy = try Scratch([], extension: "tif")
            let destination = try XCTUnwrap(
                CGImageDestinationCreateWithURL(copy.url as CFURL, "public.tiff" as CFString, 1, nil))
            XCTAssertTrue(CGImageDestinationCopyImageSource(
                destination, source, [kCGImageDestinationMetadata: metadata] as CFDictionary, nil), kind.name)

            try ExifText.set(text, removing: [.make, .lensMake], inFileAt: copy.url, as: .tiff)
            try ExifGPS.setPosition(sydney, inFileAt: copy.url, as: .tiff)

            let after = try see(copy.url)
            assertText(after, kind.name)
            XCTAssertEqual(after.pixels, before.pixels, kind.name)
            XCTAssertEqual(Double(after.position[kCGImagePropertyGPSLatitude as String] ?? "") ?? .nan,
                           33.856784, accuracy: 1e-5, kind.name)
            XCTAssertEqual(after.position[kCGImagePropertyGPSLatitudeRef as String], "S", kind.name)
            XCTAssertEqual(Double(after.position[kCGImagePropertyGPSLongitude as String] ?? "") ?? .nan,
                           151.215297, accuracy: 1e-5, kind.name)
            XCTAssertEqual(after.position[kCGImagePropertyGPSLongitudeRef as String], "E", kind.name)

            // The packet the copy wrote is still read, with what it was given.
            let written = try XCTUnwrap(CGImageSourceCreateWithURL(copy.url as CFURL, nil))
            let packet = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(written, 0, nil), kind.name)
            let tag = try XCTUnwrap(CGImageMetadataCopyTagWithPath(packet, nil, "example:RollID" as CFString),
                                    kind.name)
            XCTAssertEqual(CGImageMetadataTagCopyValue(tag) as? String, "a roll", kind.name)

            // And a second write of the same things changes nothing.
            XCTAssertFalse(try ExifText.set(text, removing: [.make, .lensMake], inFileAt: copy.url, as: .tiff),
                           kind.name)
        }
    }

    /// ExifTool on the same files: it reads what was set, the same digest
    /// of the picture, and its validation finds nothing it did not find
    /// before.
    ///
    /// But for two things. A file ImageIO gave no EXIF directory gets one
    /// from this library, which does not invent the `FlashpixVersion` and
    /// `ColorSpace` ExifTool's validation then asks for (`TextTags`). And
    /// ExifTool counts a fault it finds on more than one page, `[x2]`, so
    /// the count is taken off before two lists are compared: a value this
    /// moved to an even offset is one fault fewer, not a new one.
    func testExifToolAgreesOnFilesImageIOWrote() throws {
        let notInvented: Set<String> = [
            "Warning                         : Missing required TIFF ExifIFD tag 0xa000 FlashpixVersion",
            "Warning                         : Missing required TIFF ExifIFD tag 0xa001 ColorSpace",
        ]
        func faults(_ url: URL) throws -> Set<String> {
            Set(try ExifTool.faults(url).map {
                $0.replacingOccurrences(of: #" \[x\d+\]$"#, with: "", options: .regularExpression)
            })
        }
        for kind in kinds {
            let scratch = try file(kind)
            let before = try faults(scratch.url)
            let digest = try ExifTool.everything(scratch.url)["ImageDataHash"]
            try ExifText.set(text, removing: [.make, .lensMake], inFileAt: scratch.url, as: .tiff)
            let read = try ExifTool.everything(scratch.url)
            XCTAssertEqual(read["IFD0:Model"], "Nikon FE2", kind.name)
            XCTAssertNil(read["IFD0:Make"], kind.name)
            // ExifTool reports each page's EXIF under one name, and the
            // last page's is what a report by name holds.
            if kind.pages == 1 {
                XCTAssertEqual(read["ExifIFD:DateTimeOriginal"], "2019:07:04 22:30:00", kind.name)
                XCTAssertEqual(read["ExifIFD:CreateDate"], "2020:09:13 05:26:40", kind.name)
                XCTAssertEqual(read["ExifIFD:OffsetTimeOriginal"], "+02:00", kind.name)
                XCTAssertEqual(read["ExifIFD:LensModel"], "Nikkor 50mm f/1.8", kind.name)
                XCTAssertNil(read["ExifIFD:LensMake"], kind.name)
            }
            XCTAssertEqual(read["ImageDataHash"], digest, kind.name)
            XCTAssertEqual(try faults(scratch.url).subtracting(before).subtracting(notInvented), [], kind.name)
        }
    }
}
#endif
