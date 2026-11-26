import Foundation
import AppKit

/// Raw icon bytes extracted from the container.
public struct IconAsset: Sendable {
    public let data: Data
    public let fileExtension: String

    public init(data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension
    }
}

/// Converts PNG / SVG / XPM icons into a macOS `.icns` bundle icon.
///
/// PNG and SVG are decoded by AppKit (ImageIO) first; `rsvg-convert` is used
/// as a fallback for SVG when available. If everything fails, a generated
/// gradient placeholder is used so a `.app` is always produced.
@MainActor
public final class IconComposer {
    private let runner: ProcessRunner

    public init(runner: ProcessRunner = .shared) {
        self.runner = runner
    }

    /// Returns a path to a temporary `.icns` file. The caller owns the
    /// containing directory and should remove it after copying.
    public func makeICNS(asset: IconAsset?, appName: String, tools: ToolLocations) async throws -> URL? {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("graft-icons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        var image: NSImage?

        if let asset {
            let fileExtension = normalizedExtension(asset.fileExtension)
            let sourceURL = workDirectory
                .appendingPathComponent("source")
                .appendingPathExtension(fileExtension)
            try asset.data.write(to: sourceURL)

            image = NSImage(contentsOf: sourceURL)

            if image == nil, fileExtension == "svg", let rsvg = tools.rsvgConvert {
                let convertedURL = workDirectory.appendingPathComponent("converted.png")
                let conversion = try? await runner.run(
                    rsvg,
                    ["-w", "1024", "-h", "1024", sourceURL.path, "-o", convertedURL.path],
                    options: RunOptions(timeout: 60)
                )
                if conversion?.succeeded == true {
                    image = NSImage(contentsOf: convertedURL)
                }
            }
        }

        if image == nil || image?.size == .zero {
            image = Self.placeholderIcon(name: appName)
        }

        guard let baseImage = image else {
            return nil
        }

        let iconsetURL = workDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

        let sizes: [(pixels: Int, name: String)] = [
            (16, "icon_16x16"),
            (32, "icon_16x16@2x"),
            (32, "icon_32x32"),
            (64, "icon_32x32@2x"),
            (128, "icon_128x128"),
            (256, "icon_128x128@2x"),
            (256, "icon_256x256"),
            (512, "icon_256x256@2x"),
            (512, "icon_512x512"),
            (1024, "icon_512x512@2x")
        ]

        for size in sizes {
            guard let png = Self.pngData(from: baseImage, pixelSize: size.pixels) else {
                continue
            }
            try png.write(to: iconsetURL.appendingPathComponent("\(size.name).png"))
        }

        let icnsURL = workDirectory.appendingPathComponent("AppIcon.icns")
        let iconutil = tools.iconutil ?? "/usr/bin/iconutil"
        let conversion = try? await runner.run(
            iconutil,
            ["-c", "icns", iconsetURL.path, "-o", icnsURL.path],
            options: RunOptions(timeout: 60)
        )
        guard conversion?.succeeded == true,
              FileManager.default.fileExists(atPath: icnsURL.path) else {
            return nil
        }
        return icnsURL
    }

    private func normalizedExtension(_ raw: String) -> String {
        switch raw.lowercased() {
        case "svg", "svgz": return "svg"
        case "jpg", "jpeg": return "jpg"
        case "xpm": return "xpm"
        default: return "png"
        }
    }

    // MARK: - Rendering

    private static func pngData(from image: NSImage, pixelSize: Int) -> Data? {
        guard pixelSize > 0,
              let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelSize,
                pixelsHigh: pixelSize,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else {
            return nil
        }
        representation.size = NSSize(width: pixelSize, height: pixelSize)

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context

        let canvas = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        NSColor.clear.setFill()
        canvas.fill()

        let sourceSize = image.size
        if sourceSize.width > 0, sourceSize.height > 0 {
            let scale = min(
                CGFloat(pixelSize) / sourceSize.width,
                CGFloat(pixelSize) / sourceSize.height
            )
            let width = sourceSize.width * scale
            let height = sourceSize.height * scale
            let target = NSRect(
                x: (CGFloat(pixelSize) - width) / 2,
                y: (CGFloat(pixelSize) - height) / 2,
                width: width,
                height: height
            )
            image.draw(in: target, from: NSRect.zero, operation: .sourceOver, fraction: 1)
        }

        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [:])
    }

    private static func placeholderIcon(name: String, size: CGFloat = 1024) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        let inset = size * 0.06
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            xRadius: size * 0.2,
            yRadius: size * 0.2
        )
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.12, green: 0.38, blue: 0.82, alpha: 1),
            NSColor(calibratedRed: 0.28, green: 0.72, blue: 0.94, alpha: 1)
        ])
        gradient?.draw(in: path, angle: -45)

        let letter = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.42, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: letter.isEmpty ? "L" : letter, attributes: attributes)
        let stringSize = string.size()
        string.draw(at: NSPoint(
            x: (size - stringSize.width) / 2,
            y: (size - stringSize.height) / 2
        ))

        image.unlockFocus()
        return image
    }
}
