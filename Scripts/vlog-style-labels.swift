import AppKit

// Static labels for the review sheet; all subtitle pixels come from VeloEdit.
let labels = CommandLine.arguments.contains("--three")
    ? ["ВЛОГ", "ПУТЕШЕСТВИЕ", "СОЦСЕТИ"]
    : ["1 · КИНОШНЫЙ", "2 · ВЛОГ", "3 · ПУТЕШЕСТВИЕ", "4 · СОЦСЕТИ"]
let columns = labels.count == 3 ? 3 : 2
let width = columns * 720, height = ((labels.count + columns - 1) / columns) * 1344
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
for (index, label) in labels.enumerated() {
    let x = (index % columns) * 720
    let y = height - (index / columns) * 1344 - 64
    NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.085, alpha: 1).setFill()
    NSRect(x: x, y: y, width: 720, height: 64).fill()
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (label as NSString).draw(in: NSRect(x: x + 12, y: y + 12, width: 696, height: 43), withAttributes: [
        .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ])
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
