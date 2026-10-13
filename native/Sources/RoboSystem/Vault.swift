// Robo's Obsidian vault: where drafts, plans and notes are written, and how one is shown.
// Port of src/robo/vault.py (macOS only).
//
// Hermes writes the notes (it is told the vault path through {{VAULT}} in its templates); this
// file only creates the vault, lists it in Obsidian and opens a note.
import Foundation

public enum Vault {
    public static let folders = ["Drafts", "Plans", "Notes"]  // notes are .md files directly inside these

    /// The one source of truth for the vault; templates get it as {{VAULT}}.
    public static func dir(home: URL) -> URL {
        home.appendingPathComponent("Documents").appendingPathComponent("Robo")
    }

    static func macAppDirs(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    /// `apps`: the Applications folders to look in (default: system and user).
    public static func obsidianInstalled(home: URL, apps: [URL]? = nil) -> Bool {
        (apps ?? macAppDirs(home: home)).contains { Host.isDirectory($0.appendingPathComponent("Obsidian.app")) }
    }

    /// Is Obsidian running? When it cannot be told, yes, so its settings are left alone.
    public static func obsidianRunning(
        run: ([String], TimeInterval) throws -> ProcessOutput = Host.run) -> Bool {
        (try? run(["pgrep", "-x", "Obsidian"], 5).status == 0) ?? true
    }

    /// Obsidian's own list of vaults.
    public static func obsidianConfig(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    }

    /// `obsidian://open?path=` plus the whole path, percent-encoded (only unreserved characters stay).
    public static func obsidianURI(_ path: URL) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~")
        return "obsidian://open?path=" + Host.path(path).addingPercentEncoding(withAllowedCharacters: unreserved)!
    }

    /// Show a note in Obsidian (else in the app macOS has for .md) without waiting for it.
    ///
    /// front=false opens it behind what you are doing (`open -g`).
    public static func openNote(_ path: URL, home: URL, front: Bool = true, apps: [URL]? = nil,
                                spawn: ([String]) throws -> Void = Host.spawn) throws {
        let target = obsidianInstalled(home: home, apps: apps) ? obsidianURI(path) : Host.path(path)
        try spawn(["open"] + (front ? [] : ["-g"]) + [target])
    }

    /// List the vault in Obsidian's config. Returns what happened, "" if it was already there.
    static func register(_ vault: URL, in config: URL, running: () -> Bool) -> String {
        let vaultPath = Host.path(vault)
        let how = "in Obsidian choose 'Open folder as vault' and pick \(vaultPath)"
        guard Host.exists(config) else {
            return "Obsidian has not been set up here yet: install it, open it once, then \(how)"
        }
        let data: JSON
        let known: [String?]  // each listed vault's path, nil if it has none
        do {
            data = try JSON.parse(Host.readText(config))
            guard case .object(let top) = data else { throw JSON.Bad() }
            var entries: [(String, JSON)] = []
            if let v = top.first(where: { $0.0 == "vaults" })?.1 {
                guard case .object(let e) = v else { throw JSON.Bad() }
                entries = e
            }
            known = try entries.map {
                guard case .object(let entry) = $0.1 else { throw JSON.Bad() }
                guard case .string(let path)? = entry.first(where: { $0.0 == "path" })?.1 else { return nil }
                return path
            }
        } catch {
            return "I could not read Obsidian's vault list (\(Host.path(config))): \(how)"
        }
        if known.contains(vaultPath) { return "" }  // == also equates "é" spelled composed or decomposed
        if running() {  // it rewrites the file on quit and would undo the edit
            return "Obsidian is open, so I left its settings alone: quit it and run `robo setup` again, or \(how)"
        }
        let token = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let ts = String(Int(Date().timeIntervalSince1970 * 1000))
        let entry = JSON.object([("path", .string(vaultPath)), ("ts", .number(ts))])
        let text = data.adding(vault: token, entry).text
        guard wellFormed(text) else {
            return "I could not update Obsidian's vault list (the result would not be valid JSON): \(how)"
        }
        do {
            try Host.replaceFile(config, with: text)
        } catch {
            return "I could not update Obsidian's vault list (\(error.localizedDescription)): \(how)"
        }
        return "added your Robo vault to Obsidian"
    }

    /// Does Foundation's parser accept `text`? The last check before obsidian.json is replaced (Obsidian is
    /// Electron: its JSON.parse is as strict). Python's json.dumps would have written `Infinity` here.
    static func wellFormed(_ text: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }

    /// Idempotent; returns what it did (or what you still have to do). Never throws.
    public static func ensure(home: URL, vault: URL? = nil, config: URL? = nil,
                              running: () -> Bool = { obsidianRunning() }) -> [String] {
        let vault = vault ?? dir(home: home), config = config ?? obsidianConfig(home: home)
        let dirs = [vault] + folders.map { vault.appendingPathComponent($0) } + [vault.appendingPathComponent(".obsidian")]
        let fresh = dirs.filter { !Host.isDirectory($0) }
        do {
            for d in fresh { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        } catch {
            return ["could not create your Obsidian vault at \(Host.path(vault)): \(error.localizedDescription)"]
        }
        let done = fresh.isEmpty ? [] : ["created your Obsidian vault at \(Host.path(vault))"]
        return done + [register(vault, in: config, running: running)].filter { !$0.isEmpty }
    }
}

/// A JSON value that keeps the order of its keys, so Obsidian's file is rewritten the way Python's
/// `json.dumps` does it (Foundation's JSONSerialization loses the order).
enum JSON {
    struct Bad: Error {}
    case object([(String, JSON)]), array([JSON]), string(String), number(String), bool(Bool), null

    /// Parse like `json.loads`: one value, nothing after it.
    static func parse(_ text: String) throws -> JSON {
        var p = Parser(s: Array(text.unicodeScalars))
        let value = try p.value()
        p.skipSpace()
        guard p.i == p.s.count else { throw Bad() }
        return value
    }

    /// `setdefault("vaults", {})` and a new entry at the end of it.
    func adding(vault token: String, _ entry: JSON) -> JSON {
        guard case .object(var top) = self else { return self }
        var vaults: [(String, JSON)] = []
        if let i = top.firstIndex(where: { $0.0 == "vaults" }) {
            if case .object(let v) = top[i].1 { vaults = v }
            top[i].1 = .object(vaults + [(token, entry)])
        } else {
            top.append(("vaults", .object([(token, entry)])))
        }
        return .object(top)
    }

    /// `json.dumps(separators=(",", ":"), ensure_ascii=False)`.
    var text: String {
        switch self {
        case .object(let pairs): return "{" + pairs.map { JSON.quote($0.0) + ":" + $0.1.text }.joined(separator: ",") + "}"
        case .array(let items): return "[" + items.map(\.text).joined(separator: ",") + "]"
        case .string(let s): return JSON.quote(s)
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }

    private struct Parser {
        static let maxDepth = 256  // the recursion must fit a 512 KB thread stack; json.loads stops near 1000
        let s: [Unicode.Scalar]
        var i = 0
        var depth = 0

        mutating func skipSpace() { while i < s.count, " \t\n\r".unicodeScalars.contains(s[i]) { i += 1 } }

        mutating func expect(_ word: String) throws {
            for c in word.unicodeScalars {
                guard i < s.count, s[i] == c else { throw Bad() }
                i += 1
            }
        }

        mutating func value() throws -> JSON {
            depth += 1
            defer { depth -= 1 }
            guard depth <= Parser.maxDepth else { throw Bad() }
            skipSpace()
            guard i < s.count else { throw Bad() }
            switch s[i] {
            case "{":
                i += 1
                var pairs: [(String, JSON)] = []
                skipSpace()
                if i < s.count, s[i] == "}" { i += 1; return .object(pairs) }
                while true {
                    skipSpace()
                    guard i < s.count, s[i] == "\"" else { throw Bad() }
                    let key = try string()
                    skipSpace()
                    try expect(":")
                    let v = try value()
                    if let k = pairs.firstIndex(where: { $0.0 == key }) { pairs[k].1 = v } else { pairs.append((key, v)) }  // dict: last wins, first position
                    skipSpace()
                    guard i < s.count else { throw Bad() }
                    i += 1
                    if s[i - 1] == "}" { return .object(pairs) }
                    guard s[i - 1] == "," else { throw Bad() }
                }
            case "[":
                i += 1
                var items: [JSON] = []
                skipSpace()
                if i < s.count, s[i] == "]" { i += 1; return .array(items) }
                while true {
                    items.append(try value())
                    skipSpace()
                    guard i < s.count else { throw Bad() }
                    i += 1
                    if s[i - 1] == "]" { return .array(items) }
                    guard s[i - 1] == "," else { throw Bad() }
                }
            case "\"": return .string(try string())
            case "t": try expect("true"); return .bool(true)
            case "f": try expect("false"); return .bool(false)
            case "n": try expect("null"); return .null
            default: return try number()
            }
        }

        mutating func string() throws -> String {
            i += 1
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]
                i += 1
                switch c {
                case "\"": return String(out)
                case "\\":
                    guard i < s.count else { throw Bad() }
                    let e = s[i]
                    i += 1
                    switch e {
                    case "\"", "\\", "/": out.append(e)
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        var code = try hex4()
                        if (0xD800..<0xDC00).contains(code), i + 1 < s.count, s[i] == "\\", s[i + 1] == "u" {
                            i += 2
                            let low = try hex4()
                            guard (0xDC00..<0xE000).contains(low) else { throw Bad() }
                            code = 0x10000 + (code - 0xD800) << 10 + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw Bad() }  // a lone surrogate cannot be kept
                        out.append(scalar)
                    default: throw Bad()
                    }
                case _ where c.value < 0x20: throw Bad()  // strict: no raw control characters
                default: out.append(c)
                }
            }
            throw Bad()
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= s.count, let n = UInt32(String(String.UnicodeScalarView(s[i..<i + 4])), radix: 16) else { throw Bad() }
            i += 4
            return n
        }

        /// The number's own text; a float is rewritten the way Python prints it (`1e3` becomes `1000.0`).
        mutating func number() throws -> JSON {
            let start = i
            var isFloat = false
            func digits() throws { let from = i; while i < s.count, ("0"..."9").contains(s[i]) { i += 1 }; if i == from { throw Bad() } }
            func at(_ chars: String) -> Bool { i < s.count && chars.unicodeScalars.contains(s[i]) }
            if at("-") { i += 1 }
            if at("0") { i += 1 } else { try digits() }
            if at(".") { i += 1; isFloat = true; try digits() }
            if at("eE") { i += 1; isFloat = true; if at("+-") { i += 1 }; try digits() }
            let token = String(String.UnicodeScalarView(s[start..<i]))
            guard !isFloat || Double(token)!.isFinite else { throw Bad() }  // 1e999 has no JSON spelling to write back
            return .number(isFloat ? "\(Double(token)!)" : token)
        }
    }
}
