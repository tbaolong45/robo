// The vault and the obsidian.json rewrites.
// Obsidian itself is never touched: the vault, its config and the Applications folders live in a temp dir.
import Foundation
import Testing
@testable import RoboSystem

private let fm = FileManager.default

private func scratch<T>(_ body: (URL) throws -> T) throws -> T {
    let dir = fm.temporaryDirectory.appendingPathComponent("robo-test-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    return try body(dir)
}

private func configWith(_ tmp: URL, _ text: String) throws -> URL {
    let cfg = tmp.appendingPathComponent("obsidian/obsidian.json")
    try fm.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: cfg)
    return cfg
}

private func slurp(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

private func json(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

private let other = #"{"vaults":{"aaaaaaaaaaaaaaaa":{"path":"/elsewhere/notes","ts":1,"open":true}},"cli":true}"#
private let aaaa = ["path": "/elsewhere/notes", "ts": 1, "open": true] as [String: Any]

@Suite struct VaultTests {
    // --- ensure ---

    @Test func ensureMakesTheTreeAndRegistersItOnce() throws {
        try scratch { tmp throws in
            let home = tmp.appendingPathComponent("Documents/Robo")
            let cfg = try configWith(tmp, other)

            let done = Vault.ensure(home: tmp, vault: home, config: cfg, running: { false })

            #expect(done == ["created your Obsidian vault at \(home.path)", "added your Robo vault to Obsidian"])
            #expect(Set(try fm.contentsOfDirectory(atPath: home.path)) == Set(Vault.folders + [".obsidian"]))
            #expect(try fm.contentsOfDirectory(atPath: home.appendingPathComponent(".obsidian").path).isEmpty)
            let data = try json(cfg)
            #expect(data["cli"] as? Bool == true)  // keys and vaults that are not ours stay as they were
            let vaults = data["vaults"] as! [String: [String: Any]]
            #expect(NSDictionary(dictionary: vaults["aaaaaaaaaaaaaaaa"]!).isEqual(to: aaaa))
            let token = Set(vaults.keys).subtracting(["aaaaaaaaaaaaaaaa"]).first!
            #expect(vaults.count == 2 && token.count == 16 && UInt64(token, radix: 16) != nil)
            let entry = vaults[token]!
            #expect(entry["path"] as? String == home.path && entry["ts"] is Int)
            #expect(!(try slurp(cfg)).contains(": "))  // compact, like Obsidian writes it
            #expect(try fm.contentsOfDirectory(atPath: cfg.deletingLastPathComponent().path) == ["obsidian.json"])  // no temp file left

            #expect(Vault.ensure(home: tmp, vault: home, config: cfg, running: { false }).isEmpty)  // nothing left to do
            #expect((try json(cfg)["vaults"] as! [String: Any]).count == 2)
        }
    }

    @Test func ensureNeverEditsObsidianWhileItRuns() throws {
        try scratch { tmp throws in
            let home = tmp.appendingPathComponent("Robo")
            let cfg = try configWith(tmp, other)
            let before = try Data(contentsOf: cfg)

            let done = Vault.ensure(home: tmp, vault: home, config: cfg, running: { true })

            #expect(try Data(contentsOf: cfg) == before)
            #expect(done[0].hasPrefix("created your Obsidian vault"))
            #expect(done[1].contains("Obsidian is open") && done[1].contains("Open folder as vault"))
            #expect(done[1].contains(home.path))
        }
    }

    @Test func aVaultObsidianAlreadyListsNeedsNothingEvenWhileItRuns() throws {
        try scratch { tmp throws in
            let home = tmp.appendingPathComponent("Robo")
            let cfg = try configWith(tmp, #"{"vaults":{"bbbbbbbbbbbbbbbb":{"path":"\#(home.path)","ts":5,"open":true}}}"#)
            _ = Vault.ensure(home: tmp, vault: home, config: cfg, running: { true })  // makes the folders
            #expect(Vault.ensure(home: tmp, vault: home, config: cfg, running: { true }).isEmpty)
        }
    }

    @Test func aMissingObsidianConfigIsAMessageNotAnError() throws {
        try scratch { tmp throws in
            let home = tmp.appendingPathComponent("Robo")
            let cfg = tmp.appendingPathComponent("nope/obsidian.json")

            let done = Vault.ensure(home: tmp, vault: home, config: cfg, running: { false })

            #expect(done.last!.contains("Open folder as vault") && done.last!.contains(home.path))
            #expect(done.last!.hasPrefix("Obsidian has not been set up here yet"))
            #expect(!fm.fileExists(atPath: cfg.path) && Host.isDirectory(home.appendingPathComponent("Notes")))
        }
    }

    // What the parser or the shape checks refuse; the file must stay exactly as it was.
    @Test(arguments: [
        "{not json", "[]", #"{"vaults": []}"#, #"{"vaults": {"a": 3}}"#, "",
        #"{"a":01}"#, #"{"a":1} x"#, "[1,]", #""just a string""#, "null", #"{"vaults": null}"#,
        "{\"a\":\"x\ty\"}", #"{"a":"\x"}"#, #"{"a":+1}"#,
        #"{"vaults":{"a":null}}"#, #"{"vaults":{"a":[]}}"#, #"{"a":-}"#, #"{"a":1.}"#, #"{"a":1e}"#, #"{"a":"\ud83"}"#,
    ])
    func aCorruptObsidianConfigIsLeftAloneWithAMessage(text: String) throws {
        try scratch { tmp throws in
            let home = tmp.appendingPathComponent("Robo")
            let cfg = try configWith(tmp, text)

            let done = Vault.ensure(home: tmp, vault: home, config: cfg, running: { false })

            #expect(try slurp(cfg) == text)
            #expect(done.last!.contains("Open folder as vault"))
            #expect(done.last!.hasPrefix("I could not read Obsidian's vault list"), "\(text.debugDescription)")
        }
    }

    @Test func anObsidianConfigWithoutVaultsGetsTheKey() throws {
        try scratch { tmp throws in
            let cfg = try configWith(tmp, #"{"cli": false}"#)
            _ = Vault.ensure(home: tmp, vault: tmp.appendingPathComponent("Robo"), config: cfg, running: { false })
            let data = try json(cfg)
            #expect(data["cli"] as? Bool == false && (data["vaults"] as! [String: Any]).count == 1)
        }
    }

    // Values that cannot be written back faithfully: the file is left alone and the user told.
    @Test(arguments: [
        #"{"vaults":{},"x":1e999}"#, #"{"vaults":{},"x":-1e999}"#, #"{"vaults":{},"x":1.5E+400}"#,
        #"{"vaults":{},"x":"\ud800"}"#, #"{"vaults":{},"x":"\udc00 tail"}"#, #"{"vaults":{},"x":"\ud800A"}"#,
    ])
    func aFileTheWriterCannotKeepFaithfullyIsLeftAlone(text: String) throws {
        try scratch { tmp throws in
            let home = tmp.appendingPathComponent("Robo")
            let cfg = try configWith(tmp, text)
            let done = Vault.ensure(home: tmp, vault: home, config: cfg, running: { false })
            #expect(try slurp(cfg) == text)
            #expect(done.last!.hasPrefix("I could not") && done.last!.contains("Open folder as vault"), "\(done)")
        }
    }

    @Test func nestingTooDeepForTheParserIsRefusedNotACrash() throws {
        try scratch { tmp throws in
            for depth in [600, 20_000] {
                let deep = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
                let text = "{\"vaults\":{},\"deep\":" + deep + "}"
                let cfg = try configWith(tmp, text)
                let done = Vault.ensure(home: tmp, vault: tmp.appendingPathComponent("Robo"), config: cfg, running: { false })
                #expect(try slurp(cfg) == text)
                #expect(done.last!.hasPrefix("I could not read Obsidian's vault list"), "depth \(depth): \(done)")
            }
            let fine = "{\"vaults\":{},\"deep\":" + String(repeating: "[", count: 200) + String(repeating: "]", count: 200) + "}"
            let cfg = try configWith(tmp, fine)
            #expect(Vault.ensure(home: tmp, vault: tmp.appendingPathComponent("Robo"), config: cfg, running: { false }).last
                    == "added your Robo vault to Obsidian")
        }
    }

    @Test func aConfigThatIsNotUTF8IsLeftAloneToo() throws {
        try scratch { tmp throws in
            let cfg = tmp.appendingPathComponent("obsidian.json")
            try Data([0x7B, 0xFF, 0x7D]).write(to: cfg)
            let done = Vault.ensure(home: tmp, vault: tmp.appendingPathComponent("Robo"), config: cfg, running: { false })
            #expect(try Data(contentsOf: cfg) == Data([0x7B, 0xFF, 0x7D]))
            #expect(done.last!.hasPrefix("I could not read"))
        }
    }

    @Test func anUncreatableVaultIsAMessage() throws {
        try scratch { tmp throws in
            try Data("x".utf8).write(to: tmp.appendingPathComponent("file"))
            let done = Vault.ensure(home: tmp, vault: tmp.appendingPathComponent("file/Robo"),
                                    config: try configWith(tmp, other), running: { false })
            #expect(done.count == 1 && done[0].hasPrefix("could not create your Obsidian vault"))
        }
    }

    @Test func ensureDefaultsComeFromTheHome() throws {
        try scratch { tmp throws in
            let cfg = Vault.obsidianConfig(home: tmp)
            try fm.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(other.utf8).write(to: cfg)
            _ = Vault.ensure(home: tmp, running: { false })
            #expect(Host.isDirectory(tmp.appendingPathComponent("Documents/Robo/Plans")))
            #expect(try slurp(cfg).contains(tmp.appendingPathComponent("Documents/Robo").path))
        }
    }

    // Everything Obsidian keeps there survives the rewrite; the key order does not matter to it.
    @Test(arguments: [
        "{\n  \"cli\": true,\n  \"frame\": \"native\",\n  \"vaults\": {\n    \"b\": {\n      \"path\": \"/x/\\u00e9\",\n      \"ts\": 5,\n      \"open\": true\n    }\n  },\n  \"list\": [1, 2.5, null, \"\\u00e9\\ud83d\\ude00\", {\"z\": 1, \"a\": [true, false]}],\n  \"n\": null\n}",
        "{\"vaults\":{\"c\":{\"path\":\"/p \\n\\t\\\"\\\\\\/ \\b\\f\\u0001\\u007f\",\"ts\":1700000000000}},\"k\":\"\\u2028\"}",
        "{\"vaults\":{\"a\":{\"path\":5},\"b\":{}}}",
        "{\"vaults\":{}}", "{}", " \t\n{ \"o\" : [ ] , \"p\" : { } }  \r\n",
    ])
    func theRewriteKeepsEverythingAndAddsOneVault(before: String) throws {
        try scratch { tmp throws in
            let home = tmp.appendingPathComponent("Robo")
            let cfg = try configWith(tmp, before)
            let done = Vault.ensure(home: tmp, vault: home, config: cfg, running: { false })
            #expect(done.last == "added your Robo vault to Obsidian")
            var after = try json(cfg)
            let old = try JSONSerialization.jsonObject(with: Data(before.utf8)) as! [String: Any]
            var vaults = after["vaults"] as! [String: Any]
            let added = vaults.keys.filter { (old["vaults"] as? [String: Any])?[$0] == nil }
            #expect(added.count == 1 && added[0].count == 16)
            let entry = vaults.removeValue(forKey: added[0]) as! [String: Any]
            #expect(entry["path"] as? String == home.path && (entry["ts"] as? Int ?? 0) > 1_700_000_000_000)
            after["vaults"] = vaults.isEmpty && old["vaults"] == nil ? nil : vaults
            #expect(NSDictionary(dictionary: after).isEqual(to: old))
        }
    }

    // --- opening a note ---

    @Test func theObsidianURIPercentEncodesTheWholePath() {
        let note = URL(fileURLWithPath: "/Users/a b/Documents/Robo/Notes/Plan #1 caf\u{E9} 100%.md")
        let uri = Vault.obsidianURI(note)
        #expect(uri == "obsidian://open?path=%2FUsers%2Fa%20b%2FDocuments%2FRobo%2FNotes%2F"
            + "Plan%20%231%20caf%C3%A9%20100%25.md")
        #expect(String(uri.dropFirst("obsidian://open?path=".count)).removingPercentEncoding == Host.path(note))
        // Foundation holds the accent decomposed in a file URL; the URI carries the composed spelling.
        #expect(Vault.obsidianURI(URL(fileURLWithPath: "/v/cafe\u{301}.md")) == "obsidian://open?path=%2Fv%2Fcaf%C3%A9.md")
        // Only the unreserved characters stay as they are.
        #expect(Vault.obsidianURI(URL(fileURLWithPath: "/a/b~c_d-e.f&z=1?q+;,:@!$'()*[].md"))
            == "obsidian://open?path=%2Fa%2Fb~c_d-e.f%26z%3D1%3Fq%2B%3B%2C%3A%40%21%24%27%28%29%2A%5B%5D.md")
    }

    @Test(arguments: [true, false])
    func openNoteUsesTheObsidianURIWhenItIsInstalled(front: Bool) throws {
        try scratch { tmp throws in
            try fm.createDirectory(at: tmp.appendingPathComponent("Obsidian.app"), withIntermediateDirectories: true)
            let note = URL(fileURLWithPath: "/v/Notes/a b.md")
            var calls: [[String]] = []
            try Vault.openNote(note, home: tmp, front: front, apps: [tmp], spawn: { calls.append($0) })
            // behind what you are doing (the login digest): `open -g`
            #expect(calls == [["open"] + (front ? [] : ["-g"]) + [Vault.obsidianURI(note)]])
        }
    }

    @Test(arguments: [true, false])
    func openNoteFallsBackToTheOSOpenerWithoutObsidian(front: Bool) throws {
        try scratch { tmp throws in
            var calls: [[String]] = []
            try Vault.openNote(URL(fileURLWithPath: "/v/Notes/a b.md"), home: tmp, front: front, apps: [tmp], spawn: { calls.append($0) })
            #expect(calls == [["open"] + (front ? [] : ["-g"]) + ["/v/Notes/a b.md"]])
        }
    }

    @Test func spawnDoesNotWaitAndStartsASessionOfItsOwn() throws {
        // vault._spawn is Popen, not run(): nothing is waited for, and the opener outlives us (new session).
        let marker = "robo-spawn-test-\(UUID().uuidString)"
        let started = Date()
        try Host.spawn(["sh", "-c", "sleep 30; :", "robo-spawn-test", marker])  // "; :" keeps sh from exec-ing sleep
        #expect(Date().timeIntervalSince(started) < 2)
        var pid: pid_t = 0
        for _ in 0..<50 where pid == 0 {  // the process takes a moment to show up
            pid = pid_t(Host.trimmed(try Host.run(["pgrep", "-f", marker], timeout: 5).stdout.split(separator: "\n").first.map(String.init) ?? "")) ?? 0
            if pid == 0 { Thread.sleep(forTimeInterval: 0.05) }
        }
        defer { if pid != 0 { kill(pid, SIGKILL) } }
        try #require(pid != 0)
        #expect(getsid(pid) == pid && getsid(pid) != getsid(0))  // its own session leader (start_new_session=True)
        let fds = try Host.run(["lsof", "-a", "-p", String(pid), "-d", "0,1,2", "-Fn"], timeout: 10).stdout
        #expect(fds.split(separator: "\n").filter { $0 == "n/dev/null" }.count == 3, "stdin, stdout and stderr go to /dev/null: \(fds)")
    }

    @Test func aMissingOpenerIsAnError() {
        #expect(throws: (any Error).self) { try Host.spawn(["robo-no-such-command-xyz"]) }
    }

    // --- what is installed / running ---

    @Test func onAMacTheDefaultApplicationsFoldersAreSystemAndUser() {
        let home = URL(fileURLWithPath: "/Users/jane")
        #expect(Vault.macAppDirs(home: home).map(\.path) == ["/Applications", "/Users/jane/Applications"])
    }

    @Test func obsidianInstalledLooksInBothApplicationsFolders() throws {
        // The folders are injected: /Applications/Obsidian.app really exists on the dev's Mac.
        try scratch { tmp throws in
            let system = tmp.appendingPathComponent("system"), user = tmp.appendingPathComponent("user")
            try fm.createDirectory(at: system, withIntermediateDirectories: true)
            try fm.createDirectory(at: user, withIntermediateDirectories: true)
            #expect(Vault.obsidianInstalled(home: tmp, apps: [system, user]) == false)  // neither holds it
            try fm.createDirectory(at: user.appendingPathComponent("Obsidian.app"), withIntermediateDirectories: true)
            #expect(Vault.obsidianInstalled(home: tmp, apps: [system, user]) == true)  // ~/Applications alone
            try fm.removeItem(at: user.appendingPathComponent("Obsidian.app"))
            try fm.createDirectory(at: system.appendingPathComponent("Obsidian.app"), withIntermediateDirectories: true)
            #expect(Vault.obsidianInstalled(home: tmp, apps: [system, user]) == true)  // /Applications alone
            try fm.removeItem(at: system.appendingPathComponent("Obsidian.app"))
            try Data().write(to: system.appendingPathComponent("Obsidian.app"))  // a file is not an app bundle
            #expect(Vault.obsidianInstalled(home: tmp, apps: [system, user]) == false)
        }
    }

    @Test func obsidianRunningAsksPgrepForTheExactProcessName() {
        var asked: [[String]] = []
        let run: ([String], TimeInterval) throws -> ProcessOutput = { argv, _ in
            asked.append(argv)
            return ProcessOutput(status: asked.count == 1 ? 0 : 1, stdout: "", stderr: "")
        }
        #expect(Vault.obsidianRunning(run: run) == true && Vault.obsidianRunning(run: run) == false)
        #expect(asked[0] == ["pgrep", "-x", "Obsidian"])
    }

    @Test func obsidianRunningAssumesYesWhenItCannotTell() {
        #expect(Vault.obsidianRunning(run: { _, _ in throw POSIXError(.ENOENT) }) == true)  // then its settings are left alone
    }

    @Test func pgrepExitsNonZeroWhenNothingMatches() {
        // The real pgrep that obsidianRunning uses by default, asked about a name no process has.
        #expect((try? Host.run(["pgrep", "-x", "robo-no-such-process-xyz"], timeout: 5).status) == 1)
    }

    @Test func theObsidianConfigPathOnAMac() {
        let home = URL(fileURLWithPath: "/Users/jane")
        #expect(Vault.obsidianConfig(home: home).path == "/Users/jane/Library/Application Support/obsidian/obsidian.json")
    }

    @Test func theVaultLivesInDocumentsAndHasTheThreeFolders() {
        // The templates track relies on exactly these names.
        #expect(Vault.folders == ["Drafts", "Plans", "Notes"])
        #expect(Vault.dir(home: URL(fileURLWithPath: "/Users/jane")).path == "/Users/jane/Documents/Robo")
    }
}
