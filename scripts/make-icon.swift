// Generates Assets/icon-1024.png: macOS-style rounded-rect app icon  - 
// dark gradient tile, white waveform, red record dot.
// Run: swift scripts/make-icon.swift  (then regenerate the .icns, see build.sh)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let size: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: ~100px transparent margin, corner radius ~22.5% of the tile.
let margin: CGFloat = 100
let tile = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let radius = tile.width * 0.225
let rounded = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.addPath(rounded)
ctx.clip()
let colors = [CGColor(red: 0.16, green: 0.17, blue: 0.22, alpha: 1),
              CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: size / 2, y: tile.maxY),
                       end: CGPoint(x: size / 2, y: tile.minY), options: [])

// Waveform: symmetric rounded bars around the center line.
let heights: [CGFloat] = [0.16, 0.30, 0.48, 0.66, 0.48, 0.30, 0.16]
let barWidth: CGFloat = 54
let gap: CGFloat = 42
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (size - totalWidth) / 2
ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1))
for h in heights {
    let barHeight = tile.height * h
    let rect = CGRect(x: x, y: (size - barHeight) / 2, width: barWidth, height: barHeight)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    ctx.fillPath()
    x += barWidth + gap
}

// Red record dot, top-right inside the tile.
ctx.setFillColor(CGColor(red: 0.92, green: 0.20, blue: 0.20, alpha: 1))
let dotRadius: CGFloat = 60
ctx.fillEllipse(in: CGRect(x: tile.maxX - dotRadius * 2 - 92, y: tile.maxY - dotRadius * 2 - 92,
                           width: dotRadius * 2, height: dotRadius * 2))

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: "Assets/icon-1024.png")
try FileManager.default.createDirectory(atPath: "Assets", withIntermediateDirectories: true)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(url.path)")
