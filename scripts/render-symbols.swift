import AppKit

// Renders the SF Symbols used by the landing demo as alpha masks.
// Usage: swift scripts/render-symbols.swift landing/icons
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let names = [
    "calendar", "gearshape", "mic", "keyboard", "clock.arrow.circlepath", "stop.fill",
    "magnifyingglass", "chart.bar", "plus.circle", "xmark", "arrow.up", "arrow.down",
]
let configuration = NSImage.SymbolConfiguration(pointSize: 25, weight: .regular)
let scale = 3.0
for name in names {
    guard
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    else { fatalError("Missing symbol \(name)") }
    let size = symbol.size
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
        pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    symbol.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    let file = output.appendingPathComponent(name.replacingOccurrences(of: ".", with: "-") + ".png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: file)
    print(file.lastPathComponent, Int(size.width), Int(size.height))
}
