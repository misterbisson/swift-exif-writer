import Foundation
@testable import ExifWriter

/// **An XMP packet as each of three writers lays one out**, built from the
/// two values it states. So a test can say what a packet should be after a
/// write without describing it: the same packet built from the new values,
/// or from none.
struct XMPFixture {
    enum Style: CaseIterable {
        /// Lightroom Classic: attributes, double quotes, a wrapper, and
        /// padding before the wrapper closes.
        case lightroom
        /// ExifTool: elements, single quotes, a wrapper, two descriptions.
        case exifTool
        /// ImageIO: elements, no wrapper, no padding, and the hemisphere
        /// said a second time in an element of its own.
        case imageIO
    }

    var style = Style.lightroom
    var latitude: String? = "36,36.366660N"
    var longitude: String? = "118,3.766680W"
    /// Spaces before the wrapper closes, for the style that has them.
    var padding = 40
    /// The prefix the packet gives the EXIF namespace.
    var prefix = "exif"

    /// The same packet stating another position, as this library spells
    /// one.
    func stating(_ position: GPSPosition?) -> XMPFixture {
        var out = self
        out.latitude = position.map { XMPPacket.text(.latitude, $0) }
        out.longitude = position.map { XMPPacket.text(.longitude, $0) }
        return out
    }

    private func letter(_ value: String?) -> String? { value?.last.map(String.init) }

    func bytes() -> [UInt8] { [UInt8](text().utf8) }

    func text() -> String {
        let p = prefix
        var lines: [String] = []
        switch style {
        case .lightroom:
            lines.append("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>")
            lines.append("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        \">")
            lines.append(" <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">")
            lines.append("  <rdf:Description rdf:about=\"\"")
            lines.append("    xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"")
            lines.append("    xmlns:dc=\"http://purl.org/dc/elements/1.1/\"")
            lines.append("    xmlns:\(p)=\"http://ns.adobe.com/exif/1.0/\"")
            lines.append("   xmp:Rating=\"1\"")
            lines.append("   xmp:CreatorTool=\"Fixture\"")
            lines.append("   \(p):GPSVersionID=\"2.2.0.0\"")
            if let latitude { lines.append("   \(p):GPSLatitude=\"\(latitude)\"") }
            if let longitude { lines.append("   \(p):GPSLongitude=\"\(longitude)\"") }
            lines.append("   \(p):GPSAltitude=\"2273/2\">")
            lines.append("   <dc:title>")
            lines.append("    <rdf:Alt>")
            lines.append("     <rdf:li xml:lang=\"x-default\">exif:GPSLatitude=\"0,0N\" is only a title</rdf:li>")
            lines.append("    </rdf:Alt>")
            lines.append("   </dc:title>")
            lines.append("  </rdf:Description>")
            lines.append(" </rdf:RDF>")
            lines.append("</x:xmpmeta>")
            lines.append(String(repeating: " ", count: padding))
            lines.append("<?xpacket end=\"w\"?>")
        case .exifTool:
            lines.append("<?xpacket begin='\u{FEFF}' id='W5M0MpCehiHzreSzNTczkc9d'?>")
            lines.append("<x:xmpmeta xmlns:x='adobe:ns:meta/' x:xmptk='Image::ExifTool 13.55'>")
            lines.append("<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>")
            lines.append("")
            lines.append(" <rdf:Description rdf:about=''")
            lines.append("  xmlns:\(p)='http://ns.adobe.com/exif/1.0/'>")
            lines.append("  <\(p):GPSAltitude>2273/2</\(p):GPSAltitude>")
            if let latitude { lines.append("  <\(p):GPSLatitude>\(latitude)</\(p):GPSLatitude>") }
            if let longitude { lines.append("  <\(p):GPSLongitude>\(longitude)</\(p):GPSLongitude>") }
            lines.append(" </rdf:Description>")
            lines.append("")
            lines.append(" <rdf:Description rdf:about=''")
            lines.append("  xmlns:xmp='http://ns.adobe.com/xap/1.0/'>")
            lines.append("  <xmp:CreatorTool>Fixture</xmp:CreatorTool>")
            lines.append("  <xmp:Rating>3</xmp:Rating>")
            lines.append(" </rdf:Description>")
            lines.append("</rdf:RDF>")
            lines.append("</x:xmpmeta>")
            lines.append("<?xpacket end='w'?>")
        case .imageIO:
            lines.append("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"XMP Core 6.0.0\">")
            lines.append("   <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">")
            lines.append("      <rdf:Description rdf:about=\"\"")
            lines.append("            xmlns:\(p)=\"http://ns.adobe.com/exif/1.0/\"")
            lines.append("            xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\">")
            lines.append("         <\(p):GPSAltitude>2273/2</\(p):GPSAltitude>")
            if let latitude {
                lines.append("         <\(p):GPSLatitudeRef>\(letter(latitude) ?? "")</\(p):GPSLatitudeRef>")
                lines.append("         <\(p):GPSLatitude>\(latitude)</\(p):GPSLatitude>")
            }
            if let longitude {
                lines.append("         <\(p):GPSLongitudeRef>\(letter(longitude) ?? "")</\(p):GPSLongitudeRef>")
                lines.append("         <\(p):GPSLongitude>\(longitude)</\(p):GPSLongitude>")
            }
            lines.append("         <xmp:CreatorTool>Fixture</xmp:CreatorTool>")
            lines.append("      </rdf:Description>")
            lines.append("   </rdf:RDF>")
            lines.append("</x:xmpmeta>")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
