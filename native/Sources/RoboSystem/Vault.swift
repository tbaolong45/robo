// Robo's Obsidian vault: where drafts, plans and notes are written, and how one is shown.
//
// The agent writes the notes (it is told the vault path through {{VAULT}} in its templates); this
// file only creates the vault, lists it in Obsidian and opens a note.
import Foundation

public enum Vault {
    public static let folders = ["Drafts", "Plans", "Notes"]  // notes are .md files directly inside these
    /// Where a note written during a run is opened in Obsidian: those folders, and the user's second brain (`Brain/`, its notes are in
    /// sub-folders; robo-brain files into it only when asked). `folders` stays what `ensure` makes: the brain is the user's to make.
    public static let opened = folders + ["Brain"]

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
        var top: [String: Any]
        var vaults: [String: Any] = [:]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any],
                  let listed = parsed["vaults"].map({ $0 as? [String: Any] }) ?? [:],
                  listed.values.allSatisfy({ $0 is [String: Any] }) else { throw CocoaError(.fileReadCorruptFile) }
            (top, vaults) = (parsed, listed)
        } catch {
            return "I could not read Obsidian's vault list (\(Host.path(config))): \(how)"
        }
        let known = vaults.values.compactMap { ($0 as? [String: Any])?["path"] as? String }
        if known.contains(vaultPath) { return "" }  // == also equates "é" spelled composed or decomposed
        if running() {  // it rewrites the file on quit and would undo the edit
            return "Obsidian is open, so I left its settings alone: quit it and run `robo setup` again, or \(how)"
        }
        let token = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        vaults[token] = ["path": vaultPath, "ts": Int(Date().timeIntervalSince1970 * 1000)] as [String: Any]
        top["vaults"] = vaults
        // 1e999 parses as infinity, and writing that raises an exception no Swift code can catch
        guard JSONSerialization.isValidJSONObject(top) else {
            return "I could not update Obsidian's vault list (the result would not be valid JSON): \(how)"
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: top, options: [.sortedKeys, .withoutEscapingSlashes])
            try Host.replaceFile(config, with: String(decoding: data, as: UTF8.self))
        } catch {
            return "I could not update Obsidian's vault list (\(error.localizedDescription)): \(how)"
        }
        return "added your Robo vault to Obsidian"
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
