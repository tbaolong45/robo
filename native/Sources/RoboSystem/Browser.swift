// Robo's own Brave: a separate profile (school logins only) that Hermes drives over CDP.
// Port of src/robo/browser.py (macOS only: no /proc).
//
// The user's everyday Brave locks its login databases while it runs, so Hermes cannot borrow it.
// Robo's Brave has its own data dir, listens on 127.0.0.1 only, runs headless, and is shown once
// (`robo signin`) so the user can sign in to Outlook, Teams and Moodle with their passkey.
import Foundation

public struct BrowserError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

public enum Browser {
    public static let port = 9333  // not 9222, which Hermes' own `/browser connect` uses
    public static let cdpURL = "http://127.0.0.1:\(port)"
    public static let macBrave = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
    public static let signinURLs = ["https://outlook.office.com/mail/", "https://teams.microsoft.com/"]
    public static let binary = findBrave()
    /// Where robo's Brave saves what it downloads. Outside `~/.hermes`, so the agent may move a file out of it.
    public static var downloadsDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Robo/Downloads") }

    /// Brave on PATH, else where its installer puts it.
    public static func findBrave(which: (String) -> String? = Host.which) -> String {
        which("brave-browser") ?? which("brave") ?? macBrave
    }

    /// Does robo's Brave answer on its debug port?
    public static func up() -> Bool {
        Host.httpStatus("\(cdpURL)/json/version", timeout: 2) == 200
    }

    /// Make robo's Brave save downloads into `folder`, and download a PDF instead of showing it. A headless Brave has no download
    /// folder, so nothing it fetched ever reached the disk; CDP's `setDownloadBehavior` does not outlive one connection, and Hermes
    /// opens a new one per call. Brave rewrites its Preferences when it exits, so this works only before a start. A Preferences file
    /// that does not parse is left alone.
    static func allowDownloads(_ dataDir: URL, into folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let profile = dataDir.appendingPathComponent("Default")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        let file = profile.appendingPathComponent("Preferences")
        var prefs: [String: Any] = [:]
        if let data = try? Data(contentsOf: file) {
            guard let old = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            prefs = old
        }
        var download = prefs["download"] as? [String: Any] ?? [:]
        download["default_directory"] = Host.path(folder)
        download["prompt_for_download"] = false
        prefs["download"] = download
        var plugins = prefs["plugins"] as? [String: Any] ?? [:]
        plugins["always_open_pdf_externally"] = true
        prefs["plugins"] = plugins
        try JSONSerialization.data(withJSONObject: prefs, options: [.sortedKeys]).write(to: file, options: .atomic)
    }

    /// Start robo's Brave unless it already answers on `port`; true if this call started it. `downloads`: where it saves files.
    @discardableResult
    public static func ensure(_ dataDir: URL, headless: Bool = true, url: String? = nil, downloads: URL? = nil,
                              up: () -> Bool = Browser.up, spawn: ([String]) throws -> Void = Host.spawn,
                              sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
                              wait: Double = 20) throws -> Bool {
        if up() { return false }
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        // cookies of the user's school accounts
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDir.path)
        if let downloads { try allowDownloads(dataDir, into: downloads) }
        var argv = [binary, "--user-data-dir=\(Host.path(dataDir))", "--remote-debugging-port=\(port)",
                    "--remote-debugging-address=127.0.0.1", "--no-first-run", "--no-default-browser-check"]
        if headless { argv.append("--headless=new") }
        do {
            try spawn(argv + (url.map { [$0] } ?? []))
        } catch {  // not installed, or installed somewhere else
            throw BrowserError("Could not start Brave (\(binary)): \(error.localizedDescription). Install it from "
                               + "https://brave.com, or put `brave` on your PATH.")
        }
        for _ in 0..<Int(wait / 0.5) {
            if up() { return true }
            sleep(0.5)
        }
        throw BrowserError("robo's Brave did not open its debug port \(port) (\(binary)).")
    }

    /// Every process with its full command line (macOS has no /proc).
    public static func ps() throws -> String {
        try Host.run(["ps", "-A", "-ww", "-o", "pid=,args="], timeout: 10).stdout
    }

    /// Main and child processes of robo's Brave (matched by its exact --user-data-dir).
    ///
    /// A space-bounded match, since a home folder may hold spaces.
    public static func pids(_ dataDir: URL, ps: () throws -> String = Browser.ps) -> [Int] {
        let flag = " --user-data-dir=\(Host.path(dataDir)) "
        guard let lines = try? ps().split(separator: "\n") else { return [] }
        var found: [Int] = []
        for line in lines {
            let (pid, _, args) = Host.partition(Host.trimmed(String(line)), " ")
            if !pid.isEmpty, pid.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(pid),
               " \(args) ".contains(flag) {
                found.append(n)
            }
        }
        return found.sorted()
    }

    /// Stop robo's Brave (SIGTERM to every process of its data dir) and wait up to 10 s for the port to close.
    public static func stop(_ dataDir: URL) {
        for pid in pids(dataDir) { kill(pid_t(pid), SIGTERM) }  // gone already, or not ours to kill: ignored
        for _ in 0..<40 {
            if !up() { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Show robo's Brave so the user can sign in; robo goes back to headless afterwards.
    public static func signin(_ dataDir: URL, extra: [String] = []) throws {
        // These go into Brave's command line, where anything but a page address (--flag) would be an option.
        if let bad = extra.first(where: { !$0.hasPrefix("https://") }) {
            throw BrowserError("Will not open \(bad.debugDescription) in robo's Brave: only https:// addresses.")
        }
        stop(dataDir)
        _ = try ensure(dataDir, headless: false, url: signinURLs[0], downloads: downloadsDir)
        for url in signinURLs.dropFirst() + extra {
            try Host.spawn([binary, "--user-data-dir=\(Host.path(dataDir))", url])  // opens a tab in that instance
        }
    }
}
