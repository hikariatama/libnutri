import AppKit

// Original vector artwork: a plate with three rising nutrient marks.
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(gray: 8.0 / 255.0, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
let cream = CGColor(red: 0.94, green: 0.96, blue: 0.90, alpha: 1)
context.setStrokeColor(cream); context.setLineWidth(27)
context.strokeEllipse(in: CGRect(x: 182, y: 182, width: 660, height: 660))
context.setFillColor(cream)
for (x, height) in [(330.0, 148.0), (468.0, 248.0), (606.0, 348.0)] {
    let bar = CGPath(roundedRect: CGRect(x: x, y: 338, width: 88, height: height),
                     cornerWidth: 44, cornerHeight: 44, transform: nil)
    context.addPath(bar); context.fillPath()
}
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
