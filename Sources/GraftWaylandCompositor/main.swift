import AppKit
import Foundation
import GraftWayland

final class CompositorWindowController: NSObject, WaylandCompositorDelegate {
    private var window: NSWindow?
    private var imageView: NSImageView?
    var demoSession: WaylandDemoSession?

    func compositor(
        _ compositor: WaylandCompositor,
        didUpdateSurface surfaceID: UInt32,
        pixels: Data,
        width: Int,
        height: Int,
        stride: Int,
        title: String?
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.render(
                pixels: pixels,
                width: width,
                height: height,
                stride: stride,
                title: title
            )
        }
    }

    private func render(pixels: Data, width: Int, height: Int, stride: Int, title: String?) {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return }

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Graft Wayland Compositor"
            window.center()
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            imageView.imageScaling = .scaleProportionallyUpOrDown
            window.contentView = imageView
            self.window = window
            self.imageView = imageView
        }
        window?.title = title ?? "Graft Wayland Compositor"
        imageView?.image = NSImage(
            cgImage: image,
            size: NSSize(width: width, height: height)
        )
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class CompositorAppDelegate: NSObject, NSApplicationDelegate {
    let compositor = WaylandCompositor(socketPath: "/tmp/graft-wayland-0")
    let controller = CompositorWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        compositor.delegate = controller
        do {
            try compositor.start()
        } catch {
            fputs("failed to start Wayland compositor: \(error)\n", stderr)
            NSApp.terminate(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            do {
                let session = try WaylandDemoClient.sendTestPattern(
                    socketPath: "/tmp/graft-wayland-0"
                )
                DispatchQueue.main.async {
                    self?.controller.demoSession = session
                }
            } catch {
                fputs("demo client failed: \(error)\n", stderr)
            }
        }
    }
}

let application = NSApplication.shared
let delegate = CompositorAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
