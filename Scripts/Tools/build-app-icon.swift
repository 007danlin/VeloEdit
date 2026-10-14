#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Legacy macOS displays the .icns pixels as supplied, without applying an
// app-icon mask. Keep the original artwork and render the same vector outline
// into every representation, including non-Retina alert and Dock sizes.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift Scripts/Tools/build-app-icon.swift source.png output.icns")
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      artwork.width == artwork.height else { fatalError("Expected square icon artwork") }

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veloedit-icon-" + UUID().uuidString)
let iconset = directory.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
            bytesPerRow: pixels * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Cannot create icon bitmap")
        }
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        context.addPath(CGPath(roundedRect: tile, cornerWidth: 184, cornerHeight: 184, transform: nil))
        context.clip()
        context.interpolationQuality = .high
        context.draw(artwork, in: tile)
        guard let image = context.makeImage() else { fatalError("Cannot render icon") }
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        let url = iconset.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("Cannot write \(name)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Cannot finish \(name)") }
    }
}
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
compiler.arguments = ["-c", "icns", "-o", outputURL.path, iconset.path]
try compiler.run()
compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { fatalError("iconutil failed") }
print(outputURL.path)
