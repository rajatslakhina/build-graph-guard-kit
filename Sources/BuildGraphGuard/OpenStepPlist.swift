import Foundation

/// A value in the OpenStep property list dialect `project.pbxproj` uses.
public indirect enum PlistValue: Hashable, Sendable {
    case string(String)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var arrayValue: [PlistValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var dictionaryValue: [String: PlistValue]? {
        if case .dictionary(let fields) = self { return fields }
        return nil
    }
}

/// A parser for the OpenStep plist subset that `project.pbxproj` actually uses.
///
/// Foundation can read this format on Apple platforms via `PropertyListSerialization`,
/// but not on Linux — and the migration gate has to run in the same CI job as the
/// rest of the checks, on whatever runner is cheapest. Parsing it here also means
/// the failure mode is a thrown `GraphDecodingError` with a byte offset rather
/// than an opaque Foundation error, which is what a reviewer reading a red CI log
/// actually needs.
///
/// The scanner works over UTF-8 bytes with an explicit index; every read is
/// bounds-checked, so a truncated file throws rather than reading past the end.
/// Container nesting is recursive descent — `parseValue` calls `parseDictionary`
/// and `parseArray`, which call back into `parseValue` — bounded by a hard
/// `maximumDepth` check rather than by the stack. (The *other* tree walk, over the
/// navigator in `XcprojDecoder.membership`, uses an explicit stack; this one does
/// not, and the depth cap is what keeps it safe.)
public enum OpenStepPlist {

    /// Maximum container nesting. `pbxproj` files are two deep in practice
    /// (`objects` → object → `buildSettings`); 64 is far past any real file and
    /// far short of anything that could exhaust memory.
    public static let maximumDepth = 64

    public static func parse(_ text: String) throws -> PlistValue {
        var scanner = Scanner(bytes: Array(text.utf8))
        try scanner.skipTrivia()
        // `pbxproj` files open with `// !$*UTF8*$!` followed by a bare dictionary.
        let value = try scanner.parseValue(depth: 0)
        try scanner.skipTrivia()
        guard scanner.isAtEnd else {
            throw GraphDecodingError.malformedPlist(
                reason: "unexpected trailing content at byte \(scanner.offset)"
            )
        }
        return value
    }

    // MARK: - Scanner

    private struct Scanner {
        let bytes: [UInt8]
        var offset: Int = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { offset >= bytes.count }

        /// The byte at the cursor, or `nil` at end of input. Every read in this
        /// parser goes through here, so there is no unchecked subscript anywhere.
        func peek(_ lookahead: Int = 0) -> UInt8? {
            let index = SaturatingMath.add(offset, lookahead)
            guard index >= 0, index < bytes.count else { return nil }
            return bytes[index]
        }

        mutating func advance(_ count: Int = 1) {
            offset = min(bytes.count, SaturatingMath.add(offset, max(0, count)))
        }

        mutating func skipTrivia() throws {
            while let byte = peek() {
                if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                    advance()
                } else if byte == 0x2F, peek(1) == 0x2F { // "//"
                    advance(2)
                    while let inner = peek(), inner != 0x0A { advance() }
                } else if byte == 0x2F, peek(1) == 0x2A { // "/*"
                    advance(2)
                    var closed = false
                    while let inner = peek() {
                        if inner == 0x2A, peek(1) == 0x2F {
                            advance(2)
                            closed = true
                            break
                        }
                        advance()
                    }
                    guard closed else {
                        throw GraphDecodingError.malformedPlist(
                            reason: "unterminated block comment at byte \(offset)"
                        )
                    }
                } else {
                    return
                }
            }
        }

        mutating func parseValue(depth: Int) throws -> PlistValue {
            guard depth <= OpenStepPlist.maximumDepth else {
                throw GraphDecodingError.malformedPlist(
                    reason: "nesting deeper than \(OpenStepPlist.maximumDepth) at byte \(offset)"
                )
            }
            try skipTrivia()
            guard let byte = peek() else {
                throw GraphDecodingError.malformedPlist(reason: "unexpected end of input")
            }
            switch byte {
            case 0x7B: return try parseDictionary(depth: depth) // {
            case 0x28: return try parseArray(depth: depth)      // (
            case 0x22: return .string(try parseQuotedString())  // "
            default: return .string(try parseBareString())
            }
        }

        mutating func parseDictionary(depth: Int) throws -> PlistValue {
            advance() // consume "{"
            var fields: [String: PlistValue] = [:]
            while true {
                try skipTrivia()
                guard let byte = peek() else {
                    throw GraphDecodingError.malformedPlist(
                        reason: "unterminated dictionary at byte \(offset)"
                    )
                }
                if byte == 0x7D { // }
                    advance()
                    return .dictionary(fields)
                }
                let key = byte == 0x22 ? try parseQuotedString() : try parseBareString()
                try skipTrivia()
                guard peek() == 0x3D else { // =
                    throw GraphDecodingError.malformedPlist(
                        reason: "expected '=' after key '\(key)' at byte \(offset)"
                    )
                }
                advance()
                let value = try parseValue(depth: SaturatingMath.add(depth, 1))
                fields[key] = value
                try skipTrivia()
                // The separator is optional before a closing brace in the wild.
                if peek() == 0x3B { advance() } // ;
            }
        }

        mutating func parseArray(depth: Int) throws -> PlistValue {
            advance() // consume "("
            var items: [PlistValue] = []
            while true {
                try skipTrivia()
                guard let byte = peek() else {
                    throw GraphDecodingError.malformedPlist(
                        reason: "unterminated array at byte \(offset)"
                    )
                }
                if byte == 0x29 { // )
                    advance()
                    return .array(items)
                }
                items.append(try parseValue(depth: SaturatingMath.add(depth, 1)))
                try skipTrivia()
                if peek() == 0x2C { advance() } // ,
            }
        }

        mutating func parseQuotedString() throws -> String {
            advance() // consume opening quote
            var scalars: [UInt8] = []
            while let byte = peek() {
                if byte == 0x22 { // closing quote
                    advance()
                    return decode(scalars)
                }
                if byte == 0x5C { // backslash
                    advance()
                    guard let escaped = peek() else {
                        throw GraphDecodingError.malformedPlist(
                            reason: "string ends inside an escape at byte \(offset)"
                        )
                    }
                    switch escaped {
                    case 0x6E: scalars.append(0x0A) // \n
                    case 0x74: scalars.append(0x09) // \t
                    case 0x72: scalars.append(0x0D) // \r
                    default: scalars.append(escaped)
                    }
                    advance()
                    continue
                }
                scalars.append(byte)
                advance()
            }
            throw GraphDecodingError.malformedPlist(
                reason: "unterminated quoted string starting before byte \(offset)"
            )
        }

        mutating func parseBareString() throws -> String {
            let start = offset
            while let byte = peek(), Scanner.isBareStringByte(byte) {
                advance()
            }
            guard offset > start, start < bytes.count else {
                throw GraphDecodingError.malformedPlist(
                    reason: "expected a value at byte \(offset)"
                )
            }
            return decode(Array(bytes[start..<offset]))
        }

        /// Reconstructs a `String` from bytes. Invalid UTF-8 is replaced rather
        /// than thrown on: a mangled byte inside a comment-adjacent string should
        /// not take down a gate that has already read the parts that matter.
        func decode(_ scalars: [UInt8]) -> String {
            String(decoding: scalars, as: UTF8.self)
        }

        /// Bytes that may appear in an unquoted token. `pbxproj` writes hex ids,
        /// identifiers, paths, versions and settings values bare.
        static func isBareStringByte(_ byte: UInt8) -> Bool {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true // 0-9 A-Z a-z
            case 0x5F, 0x2E, 0x2F, 0x24, 0x2D, 0x2B, 0x40, 0x7E, 0x2A, 0x3A: return true // _ . / $ - + @ ~ * :
            default: return false
            }
        }
    }
}
