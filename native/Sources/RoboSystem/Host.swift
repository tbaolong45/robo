// HTTP and file helpers shared by setup and the agent service, and the calendar day of a session.
import Foundation

/// A date in years 1...9999, with no time or zone: a day's chat session is named after it.
public struct CalendarDay {
    public let year: Int, month: Int, day: Int

    private static let monthDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    private static func isLeap(_ y: Int) -> Bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }

    /// nil when the date does not exist (month 13, 30 February, year 0).
    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month),
              (1...(Self.monthDays[month - 1] + (month == 2 && Self.isLeap(year) ? 1 : 0))).contains(day) else { return nil }
        (self.year, self.month, self.day) = (year, month, day)
    }

    /// The day `date` falls on in local time; today by default. Gregorian in the zone the Mac is in now (not `Calendar.current`:
    /// the user may prefer another calendar).
    public init(_ date: Date = Date()) {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .autoupdatingCurrent
        let c = local.dateComponents([.year, .month, .day], from: date)
        (year, month, day) = (c.year!, c.month!, c.day!)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

public enum Host {
    private static var lastError: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

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

    /// A path for text, command lines and files that other programs read. Foundation decomposes accents
    /// in file URLs ("é" becomes "e" + U+0301), so compose them again.
    static func path(_ url: URL) -> String { url.path.precomposedStringWithCanonicalMapping }

    /// The folder is made 0700 if it is missing (only the last directory: `mkdir -p` for the rest); the file is born 0600 as a temp
    /// file in that folder and renamed over the old one, so a crash leaves the old file or the new one, never half.
    static func atomicWrite(_ data: Data, to file: URL) throws {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString.prefix(8))")
        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createDirectory(atPath: dir.path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            // not FileManager.createFile: it writes first and applies the mode afterwards, so the key would show at 0644 for a moment
            let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw lastError }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(tmp.path, file.path) == 0 else { throw lastError }
        } catch {
            unlink(tmp.path)
            throw error
        }
    }

    /// A line on stderr.
    public static func warn(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
