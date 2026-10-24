#!/usr/bin/env swift
// make-icon.swift — draw the Sloth Suite app icon.
//
// A sloth glyph on a deep indigo field, drawn with Core Graphics so there
// are no image dependencies to install.
//
//   swift make-icon.swift <output-dir>
//
// Writes <output-dir>/icon_1024.png, which iconutil turns into icon.icns.

import Foundation
import AppKit
import CoreGraphics

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

/// Draws the sloth glyph: a slow, closed eye over a rounded indigo field.
func drawIcon(size: CGFloat) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil,
                              width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = rect.insetBy(dx: size * 0.055, dy: size * 0.055)
    let radius = size * 0.225

    // Rounded-square field with a vertical gradient.
    let field = CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(field)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: cs,
                               colors: [color(0.11, 0.14, 0.33), color(0.04, 0.05, 0.13)] as CFArray,
                               locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: inset.maxY),
                           end: CGPoint(x: 0, y: inset.minY),
                           options: [])
    ctx.restoreGState()

    // Subtle rim light.
    ctx.saveGState()
    ctx.addPath(field)
    ctx.setStrokeColor(color(1, 1, 1, 0.12))
    ctx.setLineWidth(max(1, size * 0.006))
    ctx.strokePath()
    ctx.restoreGState()

    let c = CGPoint(x: size / 2, y: size / 2)

    // The eye: a wide, closed, contented curve.
    ctx.saveGState()
    ctx.setStrokeColor(color(0.94, 0.96, 1.0, 0.95))
    ctx.setLineWidth(max(2, size * 0.055))
    ctx.setLineCap(.round)
    let eyeWidth = size * 0.42
    let eyeHeight = size * 0.11
    let eye = CGMutablePath()
    eye.move(to: CGPoint(x: c.x - eyeWidth / 2, y: c.y + eyeHeight / 2))
    eye.addQuadCurve(to: CGPoint(x: c.x + eyeWidth / 2, y: c.y + eyeHeight / 2),
                     control: CGPoint(x: c.x, y: c.y - eyeHeight))
    ctx.addPath(eye)
    ctx.strokePath()
    ctx.restoreGState()

    // Three lazy speed-lines above the eye — a sloth in motion.
    ctx.saveGState()
    ctx.setStrokeColor(color(0.22, 0.74, 0.92, 0.55))
    ctx.setLineWidth(max(1.5, size * 0.018))
    ctx.setLineCap(.round)
    for (i, yOffset) in [size * 0.20, size * 0.28, size * 0.36].enumerated() {
        let lineWidth = size * (0.30 - CGFloat(i) * 0.07)
        let start = CGPoint(x: c.x - lineWidth / 2, y: c.y + yOffset)
        let end = CGPoint(x: c.x + lineWidth / 2, y: c.y + yOffset)
        ctx.move(to: start)
        ctx.addLine(to: end)
        ctx.strokePath()
    }
    ctx.restoreGState()

    return ctx.makeImage()
}

guard let image = drawIcon(size: 1024) else {
    FileHandle.standardError.write("could not draw icon\n".data(using: .utf8)!)
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("could not encode icon\n".data(using: .utf8)!)
    exit(1)
}

let out = URL(fileURLWithPath: outputDir).appendingPathComponent("icon_1024.png")
try png.write(to: out)
print("wrote \(out.path)")
