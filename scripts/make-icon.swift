// Generates Assets/icon-1024.png: red circle on black background.
// Run: swift scripts/make-icon.swift
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.setFillColor(CGColor(red: 0.88, green: 0.11, blue: 0.14, alpha: 1))
let inset = CGFloat(size) * 0.22
ctx.fillEllipse(in: CGRect(x: inset, y: inset,
                           width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset))
let image = ctx.makeImage()!
let url = URL(fileURLWithPath: "Assets/icon-1024.png")
try FileManager.default.createDirectory(atPath: "Assets", withIntermediateDirectories: true)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(url.path)")
