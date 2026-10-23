// What is behind the card: the mean luma of the screen under a rectangle, read through ScreenCaptureKit (a 16 px picture of
// it, nothing stored or sent). It needs Screen Recording, which the user grants once; without it, and on every error,
// the answer is nil and the card keeps the system's own look. Robo's own windows are left out of the picture, or the card
// would measure itself and flip forever. Main thread only (the answer comes back there too).
import AppKit
import RoboCore
import ScreenCaptureKit

final class Backdrop: @unchecked Sendable {
    static let shared = Backdrop()
    static let width = 16  // px of the picture: a mean luma needs no more

    private var content: SCShareableContent?  // read and written only by the one capture in flight
    private var busy = false
    private var asked = false

    private struct Unavailable: Error {}

    /// `rect` (AppKit coordinates) in the display's own space, the way `SCStreamConfiguration.sourceRect` reads it: points from its
    /// top-left, cut to the display. nil when none of it is on the display.
    static func sourceRect(for rect: CGRect, on display: CGRect, space: ScreenSpace) -> CGRect? {
        let seen = rect.intersection(display)
        guard !seen.isNull, seen.width >= 1, seen.height >= 1 else { return nil }
        let r = space.rect(seen), d = space.rect(display)
        return CGRect(x: r.x - d.x, y: r.y - d.y, width: r.w, height: r.h)
    }

    /// The mean luma (0...1) of the screen behind `rect`, or nil. `done` runs on the main thread, at once when there is no
    /// access. A request made while a capture is in flight is dropped without a call.
    func luma(behind rect: NSRect, done: @escaping (Double?) -> Void) {
        guard CGPreflightScreenCaptureAccess() else { return done(nil) }
        guard !busy else { return }
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let space = ScreenSpace(screens.map { Display(frame: $0.frame, visible: $0.visibleFrame) }),
              let source = Self.sourceRect(for: rect, on: screen.frame, space: space) else { return done(nil) }
        busy = true
        Task { [self] in
            let luma = await look(display: id, size: screen.frame.size, source: source)
            DispatchQueue.main.async { [self] in
                busy = false
                done(luma)
            }
        }
    }

    private func look(display id: CGDirectDisplayID, size: CGSize, source: CGRect) async -> Double? {
        do {
            let filter = try await filter(display: id, size: size)
            let config = SCStreamConfiguration()
            config.sourceRect = source
            config.width = Self.width
            config.height = max(1, Int((Double(Self.width) * source.height / source.width).rounded()))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return Self.luma(of: image)
        } catch {
            content = nil  // the displays or the windows may have changed: list them again next time
            return nil
        }
    }

    /// The whole display without Robo's windows. The list of displays and apps is kept between looks and read again when this
    /// display is not in it (or has another size now), or Robo is not (a card that is not excluded would measure itself).
    private func filter(display id: CGDirectDisplayID, size: CGSize) async throws -> SCContentFilter {
        func make(_ c: SCShareableContent) -> SCContentFilter? {
            guard let display = c.displays.first(where: { $0.displayID == id && CGFloat($0.width) == size.width && CGFloat($0.height) == size.height }),
                  let me = c.applications.first(where: { $0.processID == getpid() }) else { return nil }
            return SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: [])
        }
        if let content, let filter = make(content) { return filter }
        let fresh = try await SCShareableContent.current
        content = fresh
        guard let filter = make(fresh) else { throw Unavailable() }
        return filter
    }

    // MARK: a blurred picture of the screen (BlurVeil)

    private var pictureBusy = false

    /// How blurred (the Gaussian's sigma, in px of the picture, which is half the display's size): "a little, not too much".
    static let blurSigma = 1.3
    private static let ci = CIContext()

    /// The whole display (the one whose frame is `frame`) without Robo's windows, at half size and blurred. `done` runs on the main thread
    /// with nil when there is no access, no such display, a picture is still being made or the capture failed: the caller keeps the
    /// picture it has. Use a Backdrop of its own for this: the list of displays it keeps is not shared with `luma`.
    func blurredPicture(of frame: CGRect, done: @escaping (CGImage?) -> Void) {
        guard CGPreflightScreenCaptureAccess(), !pictureBusy,
              let screen = NSScreen.screens.first(where: { $0.frame == frame }),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return done(nil) }
        pictureBusy = true
        let size = screen.frame.size
        Task { [self] in
            var result: CGImage?
            do {
                let filter = try await filter(display: id, size: size)
                let config = SCStreamConfiguration()
                config.width = max(1, Int(size.width / 2))
                config.height = max(1, Int(size.height / 2))
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = false
                result = Self.blurred(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config))
            } catch {
                content = nil
            }
            DispatchQueue.main.async { [self] in
                pictureBusy = false
                done(result)
            }
        }
    }

    /// `image` blurred (its edges extended first, so they do not fade to black).
    static func blurred(_ image: CGImage, sigma: Double = blurSigma) -> CGImage? {
        let input = CIImage(cgImage: image)
        let out = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        return ci.createCGImage(out, from: input.extent)
    }

    /// The mean luma of a picture, through the BGRA bytes `Shade.meanLuma` reads.
    static func luma(of image: CGImage) -> Double? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { p -> Bool in
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue  // B, G, R, A in memory
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? Shade.meanLuma(bgra: bytes, width: w, height: h) : nil
    }

    /// Ask for Screen Recording, once per launch and only when it is missing: the system's own dialog (answered once, it does
    /// not come back). The request is made off the main thread so a slow dialog can never hold the card or its typing.
    func requestAccess() {
        guard !asked, !CGPreflightScreenCaptureAccess() else { return }
        asked = true
        DispatchQueue.global(qos: .utility).async { _ = CGRequestScreenCaptureAccess() }
    }
}
