import Foundation

/// **The position an XMP packet states**, and the same packet with that
/// position changed or taken out.
///
/// A file can say where it was taken twice: in its EXIF, and in its XMP
/// packet as `exif:GPSLatitude` and `exif:GPSLongitude`. Some files say it
/// only in the packet. Lightroom Classic exports a PNG that way.
///
/// ## Only a position that is already there is changed
///
/// A packet that states a position is made to agree with the EXIF. A packet
/// that states none is left as it was, and no packet is made for a file
/// that has none. That is what ExifTool does with a tag it is given no
/// group for, and EXIF is where a position belongs.
///
/// ## Nothing else in the packet moves
///
/// The packet is not parsed into a tree and written out again, which would
/// change its quoting, its order and its white space. It is read as far as
/// finding where the position's text lies, and that text alone is replaced
/// or cut out.
///
/// ## The forms a position is found in
///
/// As an attribute of a top-level `rdf:Description` or as an element inside
/// one, under whatever prefix the packet gives the EXIF namespace. The
/// value as XMP spells a coordinate, `36,22.283340N` or `36,22,17N`, or as
/// a bare number, which is not XMP's form and is what ImageIO writes, with
/// the hemisphere apart in `exif:GPSLatitudeRef`. Whichever it was, it is
/// written back in XMP's own form, and a hemisphere held apart is made to
/// agree.
enum XMPPacket {
    private static let exif = "http://ns.adobe.com/exif/1.0/"
    private static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

    enum Field: String {
        case latitude = "GPSLatitude"
        case longitude = "GPSLongitude"
        case latitudeRef = "GPSLatitudeRef"
        case longitudeRef = "GPSLongitudeRef"

        var isCoordinate: Bool { self == .latitude || self == .longitude }
    }

    /// One place in the packet that states one of the four fields.
    struct Statement: Equatable {
        let field: Field
        /// The value's own bytes: between an attribute's quotes, or between
        /// an element's tags. Nil for an element that holds more than text,
        /// or nothing.
        let value: Range<Int>?
        /// What goes when the statement is taken out: an attribute and the
        /// white space before it, or an element and the line it had to
        /// itself.
        let whole: Range<Int>
    }

    // MARK: Reading

    /// The position the packet states, or nil where it states none that
    /// can be read.
    static func position(in packet: [UInt8]) throws -> GPSPosition? {
        let found = try statements(in: packet)
        func text(_ field: Field) -> String? {
            found.first { $0.field == field }?.value.map { String(decoding: packet[$0], as: UTF8.self) }
        }
        guard let latitude = text(.latitude).flatMap({ degrees($0, signedBy: text(.latitudeRef), negative: "S") }),
              let longitude = text(.longitude).flatMap({ degrees($0, signedBy: text(.longitudeRef), negative: "W") })
        else { return nil }
        return GPSPosition(latitude: latitude, longitude: longitude)
    }

    /// Degrees from a coordinate as a packet holds one.
    static func degrees(_ text: String, signedBy ref: String?, negative: Character) -> Double? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var letter = ref?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().first
        if let last = rest.last, last.isLetter {
            letter = Character(last.uppercased())
            rest = rest.dropLast()
        }
        let parts = rest.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard (1...3).contains(parts.count), !parts.contains(where: { $0 == nil || !$0!.isFinite }) else { return nil }
        let numbers = parts.compactMap { $0 }
        // Only a bare number may carry its own sign.
        guard numbers.dropFirst().allSatisfy({ $0 >= 0 }), numbers.count == 1 || numbers[0] >= 0 else { return nil }
        let size = abs(numbers[0]) + (numbers.count > 1 ? numbers[1] / 60 : 0) + (numbers.count > 2 ? numbers[2] / 3600 : 0)
        guard let letter else { return numbers[0] < 0 ? -size : size }
        return letter == negative ? -size : size
    }

    // MARK: Writing

    /// **The packet with its position set, or with nil taken out.** Nil
    /// where the packet states no position, and so has nothing to change.
    static func setting(_ position: GPSPosition?, in packet: [UInt8]) throws -> [UInt8]? {
        let found = try statements(in: packet)
        guard found.contains(where: { $0.field.isCoordinate }) else { return nil }
        var out = packet
        // From the end backwards, so what is still to be changed has not
        // moved.
        for statement in found.sorted(by: { $0.whole.lowerBound > $1.whole.lowerBound }) {
            guard let position else {
                out.removeSubrange(statement.whole)
                continue
            }
            guard let value = statement.value else {
                throw ExifWriterError.unsupported("XMP that states its position in a form this does not write")
            }
            out.replaceSubrange(value, with: [UInt8](text(statement.field, position).utf8))
        }
        return out
    }

    /// The longest a latitude and a longitude are written at.
    private static let longest: [Field: Int] = [.latitude: 13, .longitude: 14]

    /// How much longer the packet could get were its position changed
    /// again, which is the room a packet is given when it is moved.
    static func slack(in packet: [UInt8]) throws -> Int {
        try statements(in: packet).reduce(0) { sum, statement in
            sum + max(0, (longest[statement.field] ?? 0) - (statement.value?.count ?? 0))
        }
    }

    static func text(_ field: Field, _ position: GPSPosition) -> String {
        switch field {
        case .latitude: coordinate(position.latitude, "N", "S")
        case .longitude: coordinate(position.longitude, "E", "W")
        case .latitudeRef: position.latitude < 0 ? "S" : "N"
        case .longitudeRef: position.longitude < 0 ? "W" : "E"
        }
    }

    /// A coordinate as XMP spells one: whole degrees, a comma, minutes to a
    /// millionth, and the hemisphere's letter. A millionth of a minute is
    /// about 2 mm on the ground.
    ///
    /// Split in whole millionths of a minute, so a value a hair under a
    /// whole degree never comes out as 60 minutes.
    private static func coordinate(_ degrees: Double, _ positive: String, _ negative: String) -> String {
        let scale: Int64 = 1_000_000
        let total = Int64((abs(degrees) * 60 * Double(scale)).rounded())
        let fraction = String(total % scale)
        return "\(total / (60 * scale)),\(total % (60 * scale) / scale)."
            + String(repeating: "0", count: 6 - fraction.count) + fraction
            + (degrees < 0 ? negative : positive)
    }

    // MARK: What follows the packet

    /// **The packet without what follows its closing instruction**, or nil
    /// where nothing follows it but white space, or it has no closing
    /// instruction to end at.
    ///
    /// When ImageIO copies a PNG and the packet comes out shorter, it keeps
    /// the chunk's length and leaves the end of the old packet after the
    /// new one's closing line. Those bytes are text, not padding: tags the
    /// file stated before, and ExifTool reads them. They are not the
    /// packet, so a file that is written does not keep them.
    static func trimmed(_ packet: [UInt8]) throws -> [UInt8]? {
        var scanner = Scanner(packet)
        try scanner.run()
        guard let closing = scanner.closing,
              let mark = packet[closing...].firstIndex(of: 0x3E), packet[mark - 1] == 0x3F else { return nil }
        let end = mark + 1
        guard !packet[end...].allSatisfy(isSpace) else { return nil }
        return Array(packet[..<end])
    }

    // MARK: Keeping a length

    /// **The packet at exactly `length` bytes**, by adding to its padding
    /// or spending it. Nil where it is too long and has not the padding to
    /// give.
    ///
    /// A packet is made to be edited where it lies: it ends in white space
    /// for the purpose, before its closing instruction where it has one.
    static func fitted(_ packet: [UInt8], to length: Int) -> [UInt8]? {
        // Some writers end the packet's bytes with a zero or several.
        var end = packet.count
        while end > 0, packet[end - 1] == 0 { end -= 1 }
        let closing = [UInt8]("<?xpacket end".utf8)
        var at = end
        if end >= closing.count {
            for start in stride(from: end - closing.count, through: 0, by: -1)
            where packet[start] == closing[0] && Array(packet[start..<start + closing.count]) == closing {
                at = start
                break
            }
        }
        // The line break before the closing instruction stays where it is.
        if at < end, at > 0, packet[at - 1] == 0x0A { at -= 1 }
        var out = packet
        if length >= packet.count {
            out.insert(contentsOf: [UInt8](repeating: 0x20, count: length - packet.count), at: at)
            return out
        }
        let need = packet.count - length
        guard at >= need, packet[at - need..<at].allSatisfy(isSpace) else { return nil }
        out.removeSubrange(at - need..<at)
        return out
    }

    // MARK: Finding the statements

    /// Every place the packet states one of the four fields.
    static func statements(in packet: [UInt8]) throws -> [Statement] {
        var scanner = Scanner(packet)
        try scanner.run()
        return scanner.found
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// **Reads the packet as far as its tags.** Enough XML to know which
    /// element a tag opens, what its attributes are and which namespace
    /// each name is in. Not a validator: what it does not need to
    /// understand it steps over.
    private struct Scanner {
        struct Open {
            var namespaces: [String: String]
            var isRDF = false
            var isDescription = false
            /// The field this element states, and where it and its content
            /// start.
            var stating: (field: Field, start: Int, content: Int)?
            var holdsOnlyText = true
        }

        let bytes: [UInt8]
        var stack: [Open] = []
        var found: [Statement] = []
        /// Where the packet's closing instruction starts, where it has one.
        var closing: Int?

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func run() throws {
            // Text in two or four bytes a letter has a zero beside its
            // first bracket.
            if let first = bytes.firstIndex(of: 0x3C),
               (first + 1 < bytes.count && bytes[first + 1] == 0) || (first > 0 && bytes[first - 1] == 0) {
                throw ExifWriterError.unsupported("an XMP packet that is not UTF-8")
            }
            var at = 0
            while let open = bytes[at...].firstIndex(of: 0x3C) {
                if has("<?xpacket end", open) {
                    // **The packet ends here, whatever follows.** When
                    // ImageIO copies a PNG and the packet comes out
                    // shorter, it keeps the chunk's length and leaves the
                    // tail of the old packet after this line. That tail is
                    // not XML. It is not read, and a PNG's is cut off when the
                    // file is written (`trimmed`).
                    closing = open
                    break
                } else if has("<?", open) {
                    at = try end(of: "?>", from: open + 2)
                    holdsMoreThanText()
                } else if has("<!--", open) {
                    at = try end(of: "-->", from: open + 4)
                    holdsMoreThanText()
                } else if has("<![CDATA[", open) {
                    at = try end(of: "]]>", from: open + 9)
                    holdsMoreThanText()
                } else if has("<!", open) {
                    at = try end(of: ">", from: open + 2)
                } else if has("</", open) {
                    at = try end(of: ">", from: open + 2)
                    guard let closed = stack.popLast() else { throw Self.notXML }
                    if let stating = closed.stating {
                        found.append(Statement(field: stating.field,
                                               value: closed.holdsOnlyText ? stating.content..<open : nil,
                                               whole: line(stating.start..<at)))
                    }
                } else {
                    at = try tag(at: open)
                }
            }
            guard stack.isEmpty else { throw Self.notXML }
        }

        /// A start tag: its name, its attributes, and what it means here.
        /// Returns where the tag ends.
        private mutating func tag(at open: Int) throws -> Int {
            var at = open + 1
            let name = try self.name(&at)
            var attributes: [(name: String, whole: Range<Int>, value: Range<Int>)] = []
            var empty = false
            while true {
                let before = at
                skipSpace(&at)
                guard at < bytes.count else { throw Self.notXML }
                if bytes[at] == 0x3E { break }
                if bytes[at] == 0x2F {
                    guard at + 1 < bytes.count, bytes[at + 1] == 0x3E else { throw Self.notXML }
                    empty = true
                    at += 1
                    break
                }
                let attribute = try self.name(&at)
                skipSpace(&at)
                guard at < bytes.count, bytes[at] == 0x3D else { throw Self.notXML }
                at += 1
                skipSpace(&at)
                guard at < bytes.count, bytes[at] == 0x22 || bytes[at] == 0x27,
                      let close = bytes[(at + 1)...].firstIndex(of: bytes[at]) else { throw Self.notXML }
                attributes.append((attribute, before..<close + 1, at + 1..<close))
                at = close + 1
            }
            let end = at + 1

            var element = Open(namespaces: [:])
            for attribute in attributes where attribute.name == "xmlns" || attribute.name.hasPrefix("xmlns:") {
                element.namespaces[String(attribute.name.dropFirst(6))] =
                    String(decoding: bytes[attribute.value], as: UTF8.self)
            }
            let parent = stack.last
            stack.append(element)
            defer { if empty { stack.removeLast() } }
            holdsMoreThanText(above: 1)

            let (space, local) = expanded(name, isAttribute: false)
            let top = space == XMPPacket.rdf && local == "Description" && parent?.isRDF == true
            stack[stack.count - 1].isRDF = space == XMPPacket.rdf && local == "RDF"
            stack[stack.count - 1].isDescription = top

            if top {
                for attribute in attributes {
                    let (space, local) = expanded(attribute.name, isAttribute: true)
                    guard space == XMPPacket.exif, let field = Field(rawValue: local) else { continue }
                    found.append(Statement(field: field, value: attribute.value, whole: attribute.whole))
                }
            }
            if parent?.isDescription == true, space == XMPPacket.exif, let field = Field(rawValue: local) {
                if empty {
                    found.append(Statement(field: field, value: nil, whole: line(open..<end)))
                } else {
                    stack[stack.count - 1].stating = (field, open, end)
                }
            }
            return end
        }

        /// Says that the element being read holds something that is not
        /// text. `above` skips the element just opened.
        private mutating func holdsMoreThanText(above: Int = 0) {
            let index = stack.count - 1 - above
            guard index >= 0 else { return }
            stack[index].holdsOnlyText = false
        }

        /// A name and the namespace its prefix stands for here.
        private func expanded(_ name: String, isAttribute: Bool) -> (String?, String) {
            let parts = name.split(separator: ":", maxSplits: 1)
            // An attribute with no prefix is in no namespace.
            guard parts.count == 2 || !isAttribute else { return (nil, name) }
            let prefix = parts.count == 2 ? String(parts[0]) : ""
            let local = parts.count == 2 ? String(parts[1]) : name
            for scope in stack.reversed() {
                if let space = scope.namespaces[prefix] { return (space, local) }
            }
            return (nil, local)
        }

        private func name(_ at: inout Int) throws -> String {
            let start = at
            while at < bytes.count, !XMPPacket.isSpace(bytes[at]),
                  bytes[at] != 0x3D, bytes[at] != 0x3E, bytes[at] != 0x2F { at += 1 }
            guard at > start else { throw Self.notXML }
            return String(decoding: bytes[start..<at], as: UTF8.self)
        }

        private func skipSpace(_ at: inout Int) {
            while at < bytes.count, XMPPacket.isSpace(bytes[at]) { at += 1 }
        }

        private func has(_ text: String, _ at: Int) -> Bool {
            let wanted = [UInt8](text.utf8)
            return at + wanted.count <= bytes.count && Array(bytes[at..<at + wanted.count]) == wanted
        }

        /// One past the end of the next `text` at or after `from`.
        private func end(of text: String, from: Int) throws -> Int {
            let wanted = [UInt8](text.utf8)
            var at = from
            while at + wanted.count <= bytes.count {
                if bytes[at] == wanted[0], Array(bytes[at..<at + wanted.count]) == wanted { return at + wanted.count }
                at += 1
            }
            throw Self.notXML
        }

        /// The range, and with it the line it has to itself: the white
        /// space before it back to the line break, where nothing else is on
        /// the line before it.
        private func line(_ range: Range<Int>) -> Range<Int> {
            var start = range.lowerBound
            while start > 0, bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 { start -= 1 }
            guard start > 0, bytes[start - 1] == 0x0A else { return range }
            start -= 1
            if start > 0, bytes[start - 1] == 0x0D { start -= 1 }
            return start..<range.upperBound
        }

        private static let notXML = ExifWriterError.malformed("an XMP packet that is not XML")
    }
}
