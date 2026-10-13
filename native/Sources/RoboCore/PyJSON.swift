// JSON the way Python's `json` module sees it. theme.json and the `robo plan` contract were written
// against Python, and the difference shows: `30` is an int but `30.0` is not, NaN/Infinity parse,
// integers have no size limit, a repeated key keeps its first position and its last value, and error
// text is part of the CLI's output. JSONSerialization gets none of that right, so this is a small port.
import Foundation

enum PyJSON {
    case null, bool(Bool), int(Int), double(Double), string(String), array([PyJSON])
    case big(String)  // an integer literal that does not fit an Int: sign and digits
    case object([(key: String, value: PyJSON)])

    /// The value of `key` in an object (compared by code points, as Python compares str).
    func get(_ key: String) -> PyJSON? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.key.utf8.elementsEqual(key.utf8) }?.value
    }
}

/// `str(e)` of the exception Python raises, e.g. "Expecting value: line 1 column 1 (char 0)".
struct PyJSONError: Error { let message: String }

extension PyJSON {
    /// Nesting beyond this is refused (Python allows thousands; a 512 KB thread stack overflowed in a debug
    /// build at around 1000, and no real document nests past a handful).
    static let maxDepth = 200
    static let maxIntDigits = 4300  // sys.get_int_max_str_digits()

    /// `json.loads(text)`.
    static func parse(_ text: String) throws -> PyJSON {
        var p = Parser(s: Array(text.unicodeScalars))
        return try p.document()
    }

    /// `data.decode("utf-8")`: strict, and a BOM stays a character (String(data:encoding:) drops it).
    static func decodeUTF8(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return data.starts(with: [0xEF, 0xBB, 0xBF]) ? "\u{FEFF}" + text : text
    }

    /// `json.loads(data)` for UTF-8 `data`; a leading BOM is dropped like json.loads does for bytes.
    static func parse(utf8 data: Data) throws -> PyJSON {
        let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard let text = decodeUTF8(Data(bytes)) else {
            throw PyJSONError(message: "invalid UTF-8")
        }
        return try parse(text)
    }
}

private struct Parser {
    let s: [Unicode.Scalar]
    var i = 0

    func fail(_ message: String, _ pos: Int) -> PyJSONError {
        var line = 1, lastNewline = -1
        for k in 0..<pos where s[k].value == 10 { line += 1; lastNewline = k }
        let column = lastNewline < 0 ? pos + 1 : pos - lastNewline
        return PyJSONError(message: "\(message): line \(line) column \(column) (char \(pos))")
    }

    mutating func skipSpace() {
        while i < s.count, [" ", "\t", "\n", "\r"].contains(s[i]) { i += 1 }
    }

    mutating func document() throws -> PyJSON {
        if s.first?.value == 0xFEFF { throw fail("Unexpected UTF-8 BOM (decode using utf-8-sig)", 0) }
        skipSpace()
        let v = try value(0)
        skipSpace()
        if i != s.count { throw fail("Extra data", i) }
        return v
    }

    func has(_ word: String) -> Bool {
        let w = Array(word.unicodeScalars)
        return i + w.count <= s.count && Array(s[i..<i + w.count]) == w
    }

    mutating func value(_ depth: Int) throws -> PyJSON {
        guard i < s.count else { throw fail("Expecting value", i) }
        switch s[i] {
        case "\"": i += 1; return .string(try string(begin: i - 1))
        case "{": return try object(depth)
        case "[": return try array(depth)
        case "n" where has("null"): i += 4; return .null
        case "t" where has("true"): i += 4; return .bool(true)
        case "f" where has("false"): i += 5; return .bool(false)
        case "N" where has("NaN"): i += 3; return .double(.nan)
        case "I" where has("Infinity"): i += 8; return .double(.infinity)
        case "-" where has("-Infinity"): i += 9; return .double(-.infinity)
        default: return try number()
        }
    }

    mutating func number() throws -> PyJSON {
        let start = i
        var j = i
        func digit(_ k: Int) -> Bool { k < s.count && ("0"..."9").contains(s[k]) }
        if j < s.count, s[j] == "-" { j += 1 }
        if j < s.count, ("1"..."9").contains(s[j]) {
            while digit(j) { j += 1 }
        } else if j < s.count, s[j] == "0" {
            j += 1
        } else {
            throw fail("Expecting value", start)
        }
        let intEnd = j
        if j + 1 < s.count, s[j] == ".", digit(j + 1) {
            j += 2
            while digit(j) { j += 1 }
        }
        if j < s.count, s[j] == "e" || s[j] == "E" {  // an exponent without digits is not part of the number
            var k = j + 1
            if k < s.count, s[k] == "-" || s[k] == "+" { k += 1 }
            if digit(k) {
                while digit(k) { k += 1 }
                j = k
            }
        }
        i = j
        let literal = String(String.UnicodeScalarView(s[start..<j]))
        if j == intEnd {
            let digits = intEnd - start - (s[start] == "-" ? 1 : 0)
            if digits > PyJSON.maxIntDigits {
                throw PyJSONError(message: "Exceeds the limit (\(PyJSON.maxIntDigits) digits) for integer string conversion: value has \(digits) digits; use sys.set_int_max_str_digits() to increase the limit")
            }
            return Int(literal).map { .int($0) } ?? .big(literal)
        }
        return .double(Double(literal)!)
    }

    mutating func string(begin: Int) throws -> String {
        var out = String.UnicodeScalarView()
        var j = i
        func hex4(_ at: Int) -> UInt32? {
            guard at + 4 <= s.count else { return nil }
            var v: UInt32 = 0
            for k in at..<at + 4 {
                guard let d = Character(s[k]).hexDigitValue, s[k].isASCII else { return nil }
                v = v << 4 | UInt32(d)
            }
            return v
        }
        while true {
            guard j < s.count else { throw fail("Unterminated string starting at", begin) }
            let c = s[j]
            if c == "\"" { i = j + 1; return String(out) }
            if c.value <= 0x1f { throw fail("Invalid control character at", j) }
            guard c == "\\" else { out.append(c); j += 1; continue }
            j += 1
            guard j < s.count else { throw fail("Unterminated string starting at", begin) }
            let simple: [Unicode.Scalar: Unicode.Scalar] = [
                "\"": "\"", "\\": "\\", "/": "/", "b": "\u{8}", "f": "\u{c}", "n": "\n", "r": "\r", "t": "\t"]
            if let e = simple[s[j]] { out.append(e); j += 1; continue }
            guard s[j] == "u" else { throw fail("Invalid \\escape", j - 1) }
            guard var u = hex4(j + 1) else { throw fail("Invalid \\uXXXX escape", j) }
            j += 5
            if (0xD800...0xDBFF).contains(u), j + 6 < s.count, s[j] == "\\", s[j + 1] == "u" {
                guard let low = hex4(j + 2) else { throw fail("Invalid \\uXXXX escape", j + 1) }
                if (0xDC00...0xDFFF).contains(low) {
                    u = 0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00)
                    j += 6
                }
            }
            // A lone surrogate is a legal Python str but not a Swift one: it becomes U+FFFD.
            out.append(Unicode.Scalar(u) ?? "\u{FFFD}")
        }
    }

    mutating func array(_ depth: Int) throws -> PyJSON {
        guard depth < PyJSON.maxDepth else { throw PyJSONError(message: "maximum nesting depth exceeded") }
        i += 1
        var items: [PyJSON] = []
        skipSpace()
        if i < s.count, s[i] == "]" { i += 1; return .array(items) }
        while true {
            items.append(try value(depth + 1))
            skipSpace()
            guard i < s.count else { throw fail("Expecting ',' delimiter", i) }
            if s[i] == "]" { i += 1; return .array(items) }
            guard s[i] == "," else { throw fail("Expecting ',' delimiter", i) }
            let comma = i
            i += 1
            skipSpace()
            if i < s.count, s[i] == "]" { throw fail("Illegal trailing comma before end of array", comma) }
        }
    }

    mutating func object(_ depth: Int) throws -> PyJSON {
        guard depth < PyJSON.maxDepth else { throw PyJSONError(message: "maximum nesting depth exceeded") }
        i += 1
        var pairs: [(key: String, value: PyJSON)] = []
        var index: [[UInt8]: Int] = [:]  // by UTF-8: Swift's String == also equates canonically equivalent text
        skipSpace()
        if i < s.count, s[i] == "}" { i += 1; return .object(pairs) }
        while true {
            guard i < s.count, s[i] == "\"" else {
                throw fail("Expecting property name enclosed in double quotes", i)
            }
            i += 1
            let key = try string(begin: i - 1)
            skipSpace()
            guard i < s.count, s[i] == ":" else { throw fail("Expecting ':' delimiter", i) }
            i += 1
            skipSpace()
            let v = try value(depth + 1)
            if let at = index[Array(key.utf8)] {
                pairs[at].value = v
            } else {
                index[Array(key.utf8)] = pairs.count
                pairs.append((key, v))
            }
            skipSpace()
            guard i < s.count else { throw fail("Expecting ',' delimiter", i) }
            if s[i] == "}" { i += 1; return .object(pairs) }
            guard s[i] == "," else { throw fail("Expecting ',' delimiter", i) }
            let comma = i
            i += 1
            skipSpace()
            if i < s.count, s[i] == "}" { throw fail("Illegal trailing comma before end of object", comma) }
        }
    }
}

// MARK: - repr, str and dumps

extension PyJSON {
    /// Python's `repr()` of what `json.loads` gave.
    var repr: String {
        switch self {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let n): return String(n)
        case .big(let digits): return digits
        case .double(let d): return pyFloatRepr(d)
        case .string(let t): return pyRepr(t)
        case .array(let a): return "[" + a.map(\.repr).joined(separator: ", ") + "]"
        case .object(let o): return "{" + o.map { pyRepr($0.key) + ": " + $0.value.repr }.joined(separator: ", ") + "}"
        }
    }

    /// Python's `str()`: a string as it is, everything else as its repr.
    var str: String {
        if case .string(let t) = self { return t }
        return repr
    }

    /// `json.dumps(self, ensure_ascii=False)`, or with `indent` spaces per level.
    func dumps(indent: Int? = nil) -> String {
        dump(indent, 0)
    }

    private func dump(_ indent: Int?, _ level: Int) -> String {
        func block(_ open: String, _ close: String, _ items: [String]) -> String {
            guard !items.isEmpty else { return open + close }
            guard let n = indent else { return open + items.joined(separator: ", ") + close }
            let pad = "\n" + String(repeating: " ", count: n * (level + 1))
            return open + pad + items.joined(separator: "," + pad) + "\n" + String(repeating: " ", count: n * level) + close
        }
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int, .big: return repr
        case .double(let d): return d.isNaN ? "NaN" : d.isInfinite ? (d < 0 ? "-Infinity" : "Infinity") : pyFloatRepr(d)
        case .string(let t): return jsonString(t)
        case .array(let a): return block("[", "]", a.map { $0.dump(indent, level + 1) })
        case .object(let o):
            return block("{", "}", o.map { jsonString($0.key) + ": " + $0.value.dump(indent, level + 1) })
        }
    }
}

private func jsonString(_ t: String) -> String {
    var out = "\""
    for u in t.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{8}": out += "\\b"
        case "\u{c}": out += "\\f"
        default:
            if u.value < 0x20 {
                let hex = String(u.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                out.unicodeScalars.append(u)
            }
        }
    }
    return out + "\""
}

/// Python's `repr(float)`: the shortest digits that round-trip, which Swift's `description` also gives, laid
/// out Python's way (Swift switches to an exponent from 2^53, Python from 1e16).
func pyFloatRepr(_ d: Double) -> String {
    if d.isNaN { return "nan" }
    if d.isInfinite { return d < 0 ? "-inf" : "inf" }
    var text = d.magnitude.description
    var exponent = 0
    if let e = text.firstIndex(of: "e") {
        exponent = Int(text[text.index(after: e)...])!
        text = String(text[..<e])
    }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    var digits = Array(parts.joined())
    var point = parts[0].count + exponent  // digits before the decimal point
    while digits.count > 1, digits.first == "0" { digits.removeFirst(); point -= 1 }
    while digits.count > 1, digits.last == "0" { digits.removeLast() }
    let sign = d.sign == .minus ? "-" : ""
    if digits == ["0"] { return sign + "0.0" }
    let all = String(digits)
    if point <= -4 || point > 16 {
        let rest = digits.dropFirst()
        let e = point - 1
        return sign + String(digits[0]) + (rest.isEmpty ? "" : "." + String(rest))
            + (e < 0 ? "e-" : "e+") + (abs(e) < 10 ? "0" : "") + String(abs(e))
    }
    if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + all }
    if point < digits.count { return sign + String(digits[..<point]) + "." + String(digits[point...]) }
    return sign + all + String(repeating: "0", count: point - digits.count) + ".0"
}

/// Python's `repr(str)`: quotes chosen like Python does, non-printable characters escaped.
func pyRepr(_ t: String) -> String {
    let quote: Unicode.Scalar = t.contains("'") && !t.contains("\"") ? "\"" : "'"
    var out = String.UnicodeScalarView()
    out.append(quote)
    func escape(_ v: UInt32) {
        let hex = String(v, radix: 16)
        let (prefix, width) = v <= 0xff ? ("\\x", 2) : v <= 0xffff ? ("\\u", 4) : ("\\U", 8)
        out.append(contentsOf: (prefix + String(repeating: "0", count: width - hex.count) + hex).unicodeScalars)
    }
    for u in t.unicodeScalars {
        switch u {
        case quote, "\\": out.append("\\"); out.append(u)
        case "\t": out.append(contentsOf: "\\t".unicodeScalars)
        case "\n": out.append(contentsOf: "\\n".unicodeScalars)
        case "\r": out.append(contentsOf: "\\r".unicodeScalars)
        default:
            if u.value < 0x20 || u.value == 0x7f || (u.value > 0x7f && !u.isPyPrintable) {
                escape(u.value)
            } else {
                out.append(u)
            }
        }
    }
    out.append(quote)
    return String(out)
}

extension Unicode.Scalar {
    /// `str.isprintable()` for one character: not a control, format, surrogate, private-use,
    /// unassigned or separator character (a plain space is the one separator that prints).
    var isPyPrintable: Bool {
        switch properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
            return false
        case .spaceSeparator: return self == " "
        default: return true
        }
    }

    /// `str.isspace()` for one character: Unicode White_Space plus the four ASCII separators U+001C-U+001F.
    var isPySpace: Bool { properties.isWhitespace || (0x1c...0x1f).contains(value) }
}
