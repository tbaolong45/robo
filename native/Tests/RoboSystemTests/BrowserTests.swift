// Port of tests/test_browser.py (macOS only: the /proc lookup and the Linux find_brave path are not ported),
// plus tests of the process and HTTP helpers every module shares. No test starts a real Brave, kills a real
// process or asks the machine's port 9333: `up` and `spawn` are fakes, and HTTP goes to a throwaway local server.
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

/// A one-thread HTTP server on 127.0.0.1 (a free port) that answers every request with `status`, or never
/// answers when `status` is nil. Stands in for a gateway or a browser; `requests` holds the request lines.
final class LoopbackServer {
    let port: Int
    private let lock = NSLock()
    private var seen: [String] = []
    private var stopped = false

    var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }

    init(status: Int?, location: String? = nil) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(fd, $0, size) } }
        listen(fd, 16)
        var bound = sockaddr_in(), length = size
        withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) } }
        port = Int(UInt16(bigEndian: bound.sin_port))
        Thread.detachNewThread { [weak self] in
            var held: [Int32] = []  // connections left open on purpose when there is no answer
            defer { close(fd); held.forEach { close($0) } }
            while let server = self, !server.isStopped {
                var poll_ = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poll_, 1, 100) > 0 else { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let n = read(client, &buffer, buffer.count)
                server.record(String(decoding: buffer.prefix(max(n, 0)), as: UTF8.self).components(separatedBy: "\r\n")[0])
                guard let status else { held.append(client); continue }
                let reply = "HTTP/1.1 \(status) X\r\n" + (location.map { "Location: \($0)\r\n" } ?? "")
                    + "Content-Length: 0\r\nConnection: close\r\n\r\n"
                _ = reply.withCString { write(client, $0, strlen($0)) }
                close(client)
            }
        }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func record(_ line: String) { lock.lock(); seen.append(line); lock.unlock() }
    deinit { lock.lock(); stopped = true; lock.unlock() }
}

private let app = "/Applications/Brave Browser.app/Contents"

@Suite struct BrowserTests {
    @Test func aRunningBrowserIsReused() throws {
        try scratch { tmp throws in
            var started: [[String]] = []
            #expect(try Browser.ensure(tmp.appendingPathComponent("b"), up: { true }, spawn: { started.append($0) }) == false)
            #expect(started.isEmpty)
        }
    }

    @Test func startsHeadlessBraveWithAPrivateDirAndWaits() throws {
        try scratch { tmp throws in
            var started: [[String]] = []
            var answers = [false, false, true][...]
            let d = tmp.appendingPathComponent("b")
            #expect(try Browser.ensure(d, up: { answers.popFirst()! }, spawn: { started.append($0) }, sleep: { _ in }) == true)
            // The command line Python builds, in its order.
            #expect(started == [[Browser.binary, "--user-data-dir=\(d.path)", "--remote-debugging-port=9333",
                                 "--remote-debugging-address=127.0.0.1", "--no-first-run", "--no-default-browser-check",
                                 "--headless=new"]])
            #expect(try fm.attributesOfItem(atPath: d.path)[.posixPermissions] as? Int == 0o700)
        }
    }

    @Test func signinIsVisible() throws {
        try scratch { tmp throws in
            var started: [[String]] = []
            var answers = [false, true][...]
            try Browser.ensure(tmp.appendingPathComponent("b"), headless: false, url: "https://x",
                               up: { answers.popFirst()! }, spawn: { started.append($0) }, sleep: { _ in })
            #expect(!started[0].contains("--headless=new") && started[0].last == "https://x")
        }
    }

    @Test func givesUpWhenThePortNeverOpens() throws {
        try scratch { tmp throws in
            var sleeps = 0
            do {
                try Browser.ensure(tmp.appendingPathComponent("b"), up: { false }, spawn: { _ in }, sleep: { _ in sleeps += 1 })
                Issue.record("expected BrowserError")
            } catch let e as BrowserError {
                #expect(e.description.contains("Brave") && e.description.contains("9333"))
                #expect(sleeps == 40)  // 20 s in half-second steps
            }
        }
    }

    @Test func aMissingBraveIsABrowserErrorNotACrash() throws {
        try scratch { tmp throws in
            do {
                try Browser.ensure(tmp.appendingPathComponent("b"), up: { false }, spawn: { _ in throw POSIXError(.ENOENT) })
                Issue.record("expected BrowserError")
            } catch let e as BrowserError {
                #expect(e.description.contains("Brave") && e.description.contains("https://brave.com"))
            }
        }
    }

    @Test func findBraveOnPathElseWhereTheInstallerPutsIt() {
        #expect(Browser.findBrave(which: { ["brave-browser": "/usr/bin/brave-browser"][$0] }) == "/usr/bin/brave-browser")
        #expect(Browser.findBrave(which: { ["brave": "/opt/brave"][$0] }) == "/opt/brave")
        #expect(Browser.findBrave(which: { _ in nil }) == Browser.macBrave)
        #expect(Browser.macBrave == "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser")
    }

    @Test func theDebugPortAndSigninPages() {
        #expect(Browser.port == 9333 && Browser.cdpURL == "http://127.0.0.1:9333")
        #expect(Browser.signinURLs == ["https://outlook.office.com/mail/", "https://teams.microsoft.com/"])
    }

    // --- pids ---

    private func ps(_ d: URL) -> String {
        """
          101 \(app)/MacOS/Brave Browser --user-data-dir=\(d.path) --headless=new
          102 \(app)/Frameworks/Brave Helper --type=renderer --user-data-dir=\(d.path)
          103 \(app)/MacOS/Brave Browser --user-data-dir=\(d.path)2
          104 /bin/zsh -l

        """
    }

    @Test func pidsReadsPsEvenWithASpaceInHome() {
        let d = URL(fileURLWithPath: "/Users/Jane Doe/brave")
        #expect(Browser.pids(d, ps: { ps(d) }) == [101, 102])  // not 103, whose dir only starts the same
    }

    @Test func pidsMatchesPythonsPartitionOfTheLines() {
        // Python's answer for these extra lines: a pid with a short line matches, "x 5 ..." is not a pid.
        let d = URL(fileURLWithPath: "/Users/Jane Doe/brave")
        let extra = ps(d) + "   99 x --user-data-dir=\(d.path)\nx 5 --user-data-dir=\(d.path)\n"
        #expect(Browser.pids(d, ps: { extra }) == [99, 101, 102])
    }

    @Test func pidsSurviveAFailingPs() {
        #expect(Browser.pids(URL(fileURLWithPath: "/x"), ps: { throw POSIXError(.ENOENT) }).isEmpty)
    }

    @Test func pidsFindARealProcessThroughPs() throws {
        try scratch { tmp throws in
            let d = tmp.appendingPathComponent("brave")
            try Host.spawn(["sh", "-c", "sleep 30; :", "robo-pids-test", "--user-data-dir=\(d.path)"])  // "; :" keeps sh from exec-ing sleep
            var found: [Int] = []
            for _ in 0..<50 where found.isEmpty {
                found = Browser.pids(d)
                if found.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
            }
            defer { found.forEach { kill(pid_t($0), SIGKILL) } }
            #expect(found.count == 1)
            #expect(Browser.pids(tmp.appendingPathComponent("other")).isEmpty)
        }
    }

    // --- the helpers under it ---

    @Test func whichFindsExecutablesOnPath() {
        #expect(Host.which("sh") != nil)
        #expect(Host.which("/bin/sh") == "/bin/sh")
        #expect(Host.which("robo-no-such-command-xyz") == nil)
        #expect(Host.which("/bin") == nil)  // a folder is not a program
        #expect(Host.which("/etc/hosts") == nil)  // nor is a file that cannot run
    }

    @Test func spawnedProcessesInheritNoOpenDescriptors() throws {
        // Popen's close_fds: Brave must not hold the microphone or a socket of the app that started it.
        try scratch { tmp throws in
            let fd = open("/dev/null", O_RDONLY)
            let high = fcntl(fd, F_DUPFD, 50)  // out of the way of the child's own redirect
            close(fd)
            defer { close(high) }
            let out = tmp.appendingPathComponent("answer")
            try Host.spawn(["sh", "-c", "[ -e /dev/fd/\(high) ]; echo $? > '\(out.path)'"])
            for _ in 0..<100 where !fm.fileExists(atPath: out.path) { Thread.sleep(forTimeInterval: 0.05) }
            Thread.sleep(forTimeInterval: 0.1)  // the shell creates the file before it writes the answer
            #expect(try String(contentsOf: out, encoding: .utf8) == "1\n")  // 1: no such descriptor in the child
        }
    }

    @Test func httpStatusReadsTheStatusOfALocalServer() {
        let ok = LoopbackServer(status: 200), unavailable = LoopbackServer(status: 503)
        #expect(Host.httpStatus("http://127.0.0.1:\(ok.port)/json/version", timeout: 5) == 200)
        #expect(ok.requests.first?.hasPrefix("GET /json/version ") == true)
        #expect(Host.httpStatus("http://127.0.0.1:\(unavailable.port)/health", timeout: 5) == 503)
    }

    @Test func httpStatusIsNilWhenNothingAnswers() {
        #expect(Host.httpStatus("http://127.0.0.1:9/", timeout: 1) == nil)  // refused
        let silent = LoopbackServer(status: nil)
        let started = Date()
        #expect(Host.httpStatus("http://127.0.0.1:\(silent.port)/", timeout: 0.5) == nil)  // accepted, never answered
        #expect(Date().timeIntervalSince(started) < 2)  // the per-call timeout counts, not the session's 60 s
        #expect(Host.httpStatus("not a url", timeout: 1) == nil)
    }

    @Test func httpStatusDoesNotFollowARedirect() {
        // httpx.get does not either: a 3xx is "not 200", not the page it points at.
        let target = LoopbackServer(status: 200)
        let redirector = LoopbackServer(status: 302, location: "http://127.0.0.1:\(target.port)/")
        #expect(Host.httpStatus("http://127.0.0.1:\(redirector.port)/", timeout: 5) == 302)
        #expect(target.requests.isEmpty)
    }

    // --- Host.run keeps its timeout (subprocess.run(timeout=) kills the child and raises at the limit) ---

    @Test func hostRunStopsAtItsTimeoutWhileABackgroundChildHoldsThePipe() {
        // sh exits at once, but `sleep` keeps the pipe open: the call must not wait for it.
        let started = Date()
        #expect(throws: (any Error).self) { try Host.run(["sh", "-c", "sleep 3 & echo hi"], timeout: 0.5) }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func hostRunKillsAChildThatIgnoresSIGTERM() throws {
        let started = Date()
        #expect(throws: (any Error).self) { try Host.run(["sh", "-c", "trap '' TERM; sleep 4.7391; :"], timeout: 0.5) }
        #expect(Date().timeIntervalSince(started) < 2)
        Thread.sleep(forTimeInterval: 0.3)
        // the whole group is gone, not just sh: nothing is left sleeping that long
        #expect(try Host.run(["pgrep", "-f", "sleep 4.7391"], timeout: 5).status == 1)
    }

    @Test func hostRunReportsASignalledChildAsNegative() throws {
        #expect(try Host.run(["sh", "-c", "kill -9 $$"], timeout: 5).status == -9)  // like Python's returncode
        #expect(try Host.run(["sh", "-c", "exit 7"], timeout: 5).status == 7)
    }

    // --- signin only opens https pages (a value starting with -- would be a Chromium flag) ---

    @Test func signinRefusesAnythingButHTTPSBeforeTouchingTheBrowser() throws {
        try scratch { tmp throws in
            // Refused before `stop` or `ensure` run: nothing is killed or started.
            for bad in ["--remote-debugging-port=1", "http://moodle.example", "file:///etc/passwd", "", "javascript:alert(1)"] {
                #expect(throws: BrowserError.self) { try Browser.signin(tmp.appendingPathComponent("b"), extra: [bad]) }
            }
            #expect(!fm.fileExists(atPath: tmp.appendingPathComponent("b").path))
        }
    }
}

