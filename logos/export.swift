// Exports an SVG to PNGs at the specified sizes using AppKit's native
// SVG support (macOS 14+). For square SVGs the size argument is the
// edge length; for non-square SVGs the size argument is the width and
// the height is derived from the SVG's viewBox aspect ratio.
//
// Usage:
//   swift export.swift <input.svg> <output-dir> <size1,size2,...>

import AppKit
import Foundation

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("\(msg)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4 else {
    die("usage: swift export.swift <input.svg> <output-dir> <size1,size2,...>")
}

let svgURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2], isDirectory: true)
let sizes = args[3].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
guard !sizes.isEmpty else { die("no valid sizes parsed from \(args[3])") }

guard let image = NSImage(contentsOf: svgURL) else {
    die("failed to load SVG: \(svgURL.path)")
}
let natural = image.size
guard natural.width > 0, natural.height > 0 else {
    die("SVG reports zero size; viewBox missing?")
}

try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

let baseName = svgURL.deletingPathExtension().lastPathComponent
let aspect = natural.height / natural.width

for size in sizes {
    let w = size
    let h = Int((Double(size) * Double(aspect)).rounded())

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: w,
        pixelsHigh: h,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        die("failed to allocate bitmap rep at \(w)x\(h)")
    }
    rep.size = CGSize(width: w, height: h)

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        die("failed to create graphics context")
    }
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    image.draw(
        in: CGRect(origin: .zero, size: CGSize(width: w, height: h)),
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        die("failed to encode PNG at \(w)x\(h)")
    }

    let name = (w == h) ? "\(baseName)-\(w).png" : "\(baseName)-\(w)x\(h).png"
    let outPath = outURL.appendingPathComponent(name)
    do {
        try png.write(to: outPath)
        print("wrote \(outPath.lastPathComponent) (\(w)x\(h))")
    } catch {
        die("failed to write \(outPath.path): \(error)")
    }
}
