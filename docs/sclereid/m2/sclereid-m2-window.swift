import AppKit
import QuartzCore
import Darwin

private let width = 64, height = 48

private func fail(_ message: String) -> Never {
    fputs("sclereid-m2-window: \(message)\n", stderr)
    exit(1)
}

private func report(_ line: String) {
    puts(line)
    fflush(stdout)
}

private final class FrameView: NSView {
    let image: CGImage

    init(image: CGImage) {
        self.image = image
        super.init(frame: NSMakeRect(0, 0, CGFloat(width * 4), CGFloat(height * 4)))
    }

    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { fail("no drawing context") }
        context.interpolationQuality = .none
        context.draw(image, in: bounds)
    }

    func verify() {
        guard let snapshot = bitmapImageRepForCachingDisplay(in: bounds)?.retagging(with: .sRGB) else { fail("no view bitmap") }
        cacheDisplay(in: bounds, to: snapshot)
        let w = snapshot.pixelsWide, h = snapshot.pixelsHigh
        guard w >= width, h >= height else { fail("undersized view bitmap") }
        // Sample the center of every source pixel's rendered footprint, including on Retina.
        guard snapshot.bitsPerSample == 8, snapshot.samplesPerPixel == 4 else { fail("unexpected cache format") }
        var pixel = [Int](repeating: 0, count: 4)
        for y in 0..<height {
            for x in 0..<width {
                let sx = (2 * x + 1) * w / (2 * width), sy = (2 * y + 1) * h / (2 * height)
                snapshot.getPixel(&pixel, atX: sx, y: sy)
                let right = x >= width / 2, bottom = y >= height / 2
                let expected = [right == bottom ? 255 : 0, right ? 255 : 0, bottom ? 255 : 0, 255]
                guard pixel == expected else {
                    fail("unexpected rendered color at (\(x), \(y)): \(pixel)")
                }
            }
        }
    }
}

private var window: NSWindow?

private func onScreen(_ id: Int) -> Bool {
    CATransaction.flush()
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
        fail("cannot query on-screen windows")
    }
    return windows.contains { ($0[kCGWindowNumber as String] as? Int) == id }
}

private let animationWidth = 640, animationHeight = 360

private func makeImage(_ frame: Data, width: Int, height: Int) -> CGImage {
    let format = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
    guard let provider = CGDataProvider(data: frame as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: width * 4, space: space, bitmapInfo: format, provider: provider,
                              decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { fail("invalid frame") }
    return image
}

private func openWindow(_ view: NSView) -> NSWindow {
    let w = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    w.colorSpace = .sRGB
    w.isReleasedWhenClosed = false
    w.title = "Sclereid M2"
    w.contentView = view
    window = w
    w.center()
    w.orderFrontRegardless()
    w.display()
    return w
}

private func show(_ frame: Data) {
    let view = FrameView(image: makeImage(frame, width: width, height: height))
    let w = openWindow(view)
    view.verify()
    guard w.isVisible, onScreen(w.windowNumber) else { fail("window is not ordered on screen") }
    report("WINDOW_OK")
}

private func animate(_ frame: Data, width: Int, height: Int) {
    let first = window == nil
    if first {
        let view = NSView(frame: NSMakeRect(0, 0, CGFloat(width), CGFloat(height)))
        // Install a layer-hosting view so AppKit doesn't redraw over its contents.
        view.layer = CALayer()
        view.wantsLayer = true
        _ = openWindow(view)
    }
    guard let w = window, let layer = w.contentView?.layer else { fail("missing animation layer") }
    let start = CACurrentMediaTime()
    let image = makeImage(frame, width: width, height: height)
    let constructed = CACurrentMediaTime()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.contents = image
    CATransaction.commit()
    // This measures submission, not when the frame reaches the display.
    CATransaction.flush()
    let applied = CACurrentMediaTime()
    if first && !(w.isVisible && onScreen(w.windowNumber)) { fail("window is not ordered on screen") }
    report(String(format: "FRAME_OK %.6f %.6f", (constructed - start) * 1000, (applied - constructed) * 1000))
}

private func cleanup() {
    guard let w = window else { fail("no window to close") }
    let id = w.windowNumber
    w.close()
    guard !w.isVisible, !onScreen(id) else { fail("window still visible after close") }
    w.contentView = nil
    window = nil
}

private func readFrame(width: Int, height: Int) -> Data? {
    // Use fresh storage: the image provider may retain these bytes after submission.
    var frame = Data(count: width * height * 4)
    let complete = frame.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Bool in
        var offset = 0
        while offset < bytes.count {
            let n = read(STDIN_FILENO, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { fail("stdin: \(String(cString: strerror(errno)))") }
            if n == 0 && offset == 0 { return false }
            guard n > 0 else { fail("EOF after \(offset) frame bytes") }
            offset += n
        }
        return true
    }
    guard complete else { return nil }
    guard stride(from: 3, to: frame.count, by: 4).allSatisfy({ frame[$0] == 255 }) else { fail("non-opaque frame") }
    return frame
}

private func receiveSingle() {
    guard let frame = readFrame(width: width, height: height) else { fail("EOF after 0 frame bytes") }
    DispatchQueue.main.sync { show(frame) }
    var extra: UInt8 = 0
    while true {
        let n = read(STDIN_FILENO, &extra, 1)
        if n < 0 && errno == EINTR { continue }
        guard n >= 0 else { fail("stdin: \(String(cString: strerror(errno)))") }
        guard n == 0 else { fail("unexpected data after frame") }
        break
    }
}

private func receive(streamSize: (Int, Int)?) {
    if let (width, height) = streamSize {
        while let frame = readFrame(width: width, height: height) {
            DispatchQueue.main.sync { autoreleasepool { animate(frame, width: width, height: height) } }
        }
    } else {
        receiveSingle()
    }
    DispatchQueue.main.async {
        autoreleasepool {
            if streamSize != nil, let w = window, !(w.isVisible && onScreen(w.windowNumber)) {
                fail("window is not ordered on screen at EOF")
            }
            cleanup()
        }
        report("CLEANUP_OK")
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let streamSize: (Int, Int)?
switch Array(CommandLine.arguments.dropFirst()) {
case ["--animate"]: streamSize = (animationWidth, animationHeight)
case ["--weston"]: streamSize = (250, 250)
case []: streamSize = nil
default: fail("expected --animate or --weston")
}
DispatchQueue.global().async { receive(streamSize: streamSize) }
app.run()
