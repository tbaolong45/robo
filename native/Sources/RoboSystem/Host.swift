// Process, HTTP and file helpers shared by setup, the vault and robo's browser (port of the
// subprocess/httpx/pathlib calls in setup.py, vault.py and browser.py). Everything that reaches the
// machine takes these as default arguments, so tests pass fakes and a temp home instead.
import Foundation

public struct ProcessOutput {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

public enum Host {
    private static var lastError: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    /// posix_spawnp with `flags`; like Popen's close_fds the child inherits no descriptor of ours but the
    /// ones `actions` set up as its stdin, stdout and stderr.
    private static func start(_ argv: [String], flags: Int32,
                              actions: (inout posix_spawn_file_actions_t?) -> Void) throws -> pid_t {
        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        actions(&files)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(flags | POSIX_SPAWN_CLOEXEC_DEFAULT))  // pgroup 0: the child leads its own
        let args = argv.map { strdup($0) } + [nil]
        defer { args.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, argv[0], &files, &attr, args, environ)
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO) }
        return pid
    }

    /// Run `argv` (looked up on PATH) and capture its output. Like `subprocess.run(timeout=)`, it raises at the
    /// limit even if a background child still holds the pipes, and kills a child that is still running (SIGKILL,
    /// to its whole process group: SIGTERM can be ignored).
    public static func run(_ argv: [String], timeout: TimeInterval) throws -> ProcessOutput {
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]  // [read end, write end]
        guard pipe(&out) == 0 else { throw lastError }
        guard pipe(&err) == 0 else { close(out[0]); close(out[1]); throw lastError }
        let readers = [out[0], err[0]]
        defer { readers.forEach { close($0) } }
        let pid: pid_t
        do {
            pid = try start(argv, flags: POSIX_SPAWN_SETPGROUP) { files in
                posix_spawn_file_actions_addopen(&files, 0, "/dev/null", O_RDONLY, 0)
                posix_spawn_file_actions_adddup2(&files, out[1], 1)
                posix_spawn_file_actions_adddup2(&files, err[1], 2)
            }
        } catch {
            close(out[1]); close(err[1])
            throw error
        }
        close(out[1]); close(err[1])  // so that EOF means the child (and its children) let go
        var chunks = [Data(), Data()], open = [0, 1], exit: Int32?
        let end = DispatchTime.now().uptimeNanoseconds + UInt64(max(timeout, 0) * 1e9)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            var wait: Int32 = 0
            if exit == nil, waitpid(pid, &wait, WNOHANG) == pid { exit = wait }
            if exit != nil, open.isEmpty { break }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= end {
                if exit == nil { kill(-pid, SIGKILL); waitpid(pid, &wait, 0) }
                throw POSIXError(.ETIMEDOUT)
            }
            var polls = open.map { pollfd(fd: readers[$0], events: Int16(POLLIN), revents: 0) }
            poll(&polls, nfds_t(polls.count), Int32(min((end - now) / 1_000_000, open.isEmpty ? 5 : 50)))
            for (slot, p) in zip(open, polls) where p.revents != 0 {
                let n = read(p.fd, &buffer, buffer.count)
                if n > 0 { chunks[slot].append(contentsOf: buffer[..<n]) } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                    open.removeAll { $0 == slot }
                }
            }
        }
        let sig = exit! & 0x7f  // like Python's returncode: the exit code, or minus the signal that ended it
        return ProcessOutput(status: sig == 0 ? (exit! >> 8) & 0xff : -sig,
                             stdout: String(decoding: chunks[0], as: UTF8.self),
                             stderr: String(decoding: chunks[1], as: UTF8.self))
    }

    /// Start `argv` in its own session with no terminal and return at once (Popen + start_new_session);
    /// its stdin, stdout and stderr are /dev/null.
    public static func spawn(_ argv: [String]) throws {
        let pid = try start(argv, flags: POSIX_SPAWN_SETSID) { files in
            for fd: Int32 in 0...2 {
                posix_spawn_file_actions_addopen(&files, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
            }
        }
        DispatchQueue.global().async { var status: Int32 = 0; waitpid(pid, &status, 0) }  // no zombie left behind
    }

    /// `shutil.which`: the first executable file called `name` on PATH (or `name` itself if it has a slash).
    public static func which(_ name: String) -> String? {
        func executable(_ path: String) -> Bool {
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
        if name.contains("/") { return executable(name) ? name : nil }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/bin:/usr/bin"
        return path.split(separator: ":").map { "\($0)/\(name)" }.first(where: executable)
    }

    /// One session for every call (a new one per call is never freed): no proxy, no redirects, no cookies,
    /// no cache (it kept every response), like httpx with trust_env=False.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// The HTTP status of a GET, nil if it did not answer within `timeout`.
    public static func httpStatus(_ url: String, timeout: TimeInterval) -> Int? {
        guard let url = URL(string: url) else { return nil }
        var status: Int?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: URLRequest(url: url, timeoutInterval: timeout)) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            done.signal()
        }.resume()
        done.wait()
        return status
    }

    /// `Path.read_text()`: strict UTF-8 that keeps a leading BOM, with "\r\n" and "\r" read as "\n".
    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard String(data: data, encoding: .utf8) != nil else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return String(decoding: data, as: UTF8.self)  // unlike String(data:), this does not drop the BOM
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// A path for text, command lines and files that other programs read. Foundation decomposes accents
    /// in file URLs ("é" becomes "e" + U+0301); Python keeps what it was given, so compose them again.
    static func path(_ url: URL) -> String { url.path.precomposedStringWithCanonicalMapping }

    /// Write `text` to a temp file beside `link`, then rename it over `link` (`os.replace`). The temp file is
    /// created with `mode` (default: 0666 less the umask) so a key is never readable by others, not even briefly.
    static func replaceFile(_ link: URL, with text: String, mode: Int? = nil) throws {
        let url = link.resolvingSymlinksInPath()  // a symlinked (dotfiles) file is updated, not replaced
        let tmp = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp")
        unlink(tmp.path)  // a leftover of a crash could have other permissions
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode ?? 0o666))
        guard fd >= 0 else { throw lastError }
        defer { unlink(tmp.path) }  // nothing left after a successful rename
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: Data(text.utf8))
        try file.close()
        if rename(tmp.path, url.path) != 0 { throw lastError }
    }

    /// A line on stderr.
    public static func warn(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    /// `str.splitlines()` for text already read with universal newlines: no empty last element.
    static func splitLines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// `str.partition(sep)` on code points: (before, found, after).
    static func partition(_ s: String, _ sep: Unicode.Scalar) -> (String, Bool, String) {
        let u = s.unicodeScalars
        guard let i = u.firstIndex(of: sep) else { return (s, false, "") }
        return (String(u[..<i]), true, String(u[u.index(after: i)...]))
    }

    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
