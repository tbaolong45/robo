// First-wake-of-the-day trigger: a persisted digest date, a resume watcher, a net wait.
// Port of src/robo/wake.py (macOS): NSWorkspace says when the Mac wakes, so Python's wall-versus-monotonic
// clock-gap trick (and the Linux login1 source) is gone. Python's wait for the user after a wake stays.
import AppKit
import Foundation

/// Remembers the local date of the last digest in a 0600 JSON file, `{"last_digest": "YYYY-MM-DD"}`
/// (the same file format as Python's, e.g. data/robo_state.json).
public struct DigestClock {
    public let path: URL

    public init(path: URL) { self.path = path }

    /// True when no digest is recorded for `today` (a missing or unreadable file counts as none).
    public func due(_ today: CalendarDay) -> Bool {
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let last = (json["last_digest"] as? String).flatMap({ CalendarDay(iso: $0) }) else { return true }
        return last != today
    }

    /// Record that today's digest was given: written to a 0600 temp file and renamed over the old one.
    public func mark(_ today: CalendarDay) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var template = Array((dir.path + "/.digest-XXXXXX").utf8CString)
        let fd = mkstemp(&template)  // mode 0600
        guard fd >= 0 else { throw ActivityLog.posixFailure() }
        let tmp = String(cString: template)
        do {
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            defer { try? file.close() }
            try file.write(contentsOf: Data("{\"last_digest\": \"\(today.iso)\"}".utf8))
            guard rename(tmp, path.path) == 0 else { throw ActivityLog.posixFailure() }
        } catch {
            unlink(tmp)
            throw error
        }
    }
}

/// Calls `onResume` from a background queue each time the Mac wakes from sleep and the user is back.
///
/// Power Nap wakes a shut Mac with nobody there, and that must not take the morning digest: after the
/// wake notification the callback waits until there has been keyboard or mouse input since the wake.
public final class WakeWatcher {
    let onResume: () -> Void
    let center: NotificationCenter
    let awake: () -> Double
    let idle: () -> Double
    let poll: Double
    let queue = DispatchQueue(label: "ai.robo.wake", qos: .utility)
    private var observer: NSObjectProtocol?
    private var timer: DispatchSourceTimer?
    private var woke: Double?  // awake time of the last wake that has not seen the user yet

    /// `awake` must not run while the Mac sleeps (the default does not); `idle` is seconds since the last input.
    public init(_ onResume: @escaping () -> Void,
                center: NotificationCenter = NSWorkspace.shared.notificationCenter,
                awake: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                idle: @escaping () -> Double = ActivityLog.macIdle, poll: Double = 0.5) {
        (self.onResume, self.center, self.awake, self.idle, self.poll) = (onResume, center, awake, idle, poll)
    }

    public func start() {
        guard observer == nil else { return }
        observer = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.didWake() }
        }
    }

    /// The Mac just woke: look for the user every `poll` s until there is input (on `queue`).
    func didWake() {
        woke = awake()
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + poll, repeating: poll)
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    /// Resume if there was input no older than the wake (on `queue`). Idle time may or may not count the
    /// sleep, so input from just before the sleep must stay old.
    func check() {
        guard let w = woke, idle() <= awake() - w else { return }
        woke = nil
        timer?.cancel()
        timer = nil
        onResume()
    }

    /// Stops watching; no callback comes after it returns. Not to be called from `onResume`.
    public func stop() {
        if let o = observer { center.removeObserver(o) }
        observer = nil
        queue.sync {
            timer?.cancel()
            timer = nil
            woke = nil
        }
    }
}

/// Probe every `interval` s until it returns true (true) or `timeout` s pass (false); a probe that throws is "down".
public func waitForNetwork(_ probe: () throws -> Bool, timeout: Double = 60, interval: Double = 2,
                           sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Bool {
    var waited = 0.0
    while true {
        if (try? probe()) == true { return true }
        if waited >= timeout { return false }
        sleep(interval)
        waited += interval
    }
}
