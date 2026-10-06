import AppKit
import Foundation

// Regeneration must preserve the solid opaque black icon in every system appearance.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
  bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(
  to: root.appendingPathComponent("Quiet/Assets.xcassets/AppIcon.appiconset/quiet.png"))
