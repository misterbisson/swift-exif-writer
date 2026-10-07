import Foundation

/// A point on the globe in decimal degrees, north and east positive.
public struct GPSPosition: Equatable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    /// Nil for a point off the globe or not a number.
    public init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// **The position a file states in each of the two places it can**, apart.
///
/// For a caller that has to know which said it: one that writes the XMP
/// with something else and needs to know whether the EXIF still wants
/// writing, or one that wants to show where two disagree.
public struct StatedPositions: Equatable, Hashable, Sendable {
    /// What the GPS block of the file's EXIF states.
    public let exif: GPSPosition?
    /// What the file's XMP packet states.
    public let xmp: GPSPosition?

    /// The position the file states: the EXIF's, and where the EXIF has
    /// none, the packet's.
    public var position: GPSPosition? { exif ?? xmp }

    public init(exif: GPSPosition?, xmp: GPSPosition?) {
        self.exif = exif
        self.xmp = xmp
    }
}

extension GPSPosition {
    /// One axis as EXIF holds it: degrees, minutes and seconds, each a pair of
    /// unsigned 32-bit numbers, and the sign carried apart as a letter.
    ///
    /// Seconds are kept to a millionth, which is about 0.03 mm on the ground.
    /// The split is done in whole millionths of a second so that a value a
    /// hair under a whole minute never comes out as 60 seconds.
    static func rationals(_ degrees: Double) -> [(UInt32, UInt32)] {
        let scale: Int64 = 1_000_000
        let total = Int64((abs(degrees) * 3600 * Double(scale)).rounded())
        let whole = total / (3600 * scale)
        let minutes = (total % (3600 * scale)) / (60 * scale)
        let seconds = total % (60 * scale)
        return [(UInt32(whole), 1), (UInt32(minutes), 1), (UInt32(seconds), UInt32(scale))]
    }

    /// Degrees from one to three rationals, or nil where a denominator is
    /// zero. A lone rational is decimal degrees, and two are degrees and
    /// decimal minutes, which are both legal and both seen.
    static func degrees(_ rationals: [(Double, Double)]) -> Double? {
        guard (1...3).contains(rationals.count), !rationals.contains(where: { $0.1 == 0 }) else { return nil }
        let parts = rationals.map { $0.0 / $0.1 }
        return parts[0] + (parts.count > 1 ? parts[1] / 60 : 0) + (parts.count > 2 ? parts[2] / 3600 : 0)
    }
}
