// Generates LapCat's app icon and menu-bar glyph from the designed artwork.
//   swift scripts/make-icons.swift [source.png] [outlineReach] [gapWiden] [thicken]
// Writes Resources/AppIcon.icns and Resources/MenuBarIcon.png / MenuBarIcon@2x.png.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("docs/design/app-icon/lapcat-app_icon.png")
let resources = root.appendingPathComponent("Resources")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
else { fail("cannot read \(sourceURL.path)") }

let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

func context(_ width: Int, _ height: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("cannot create \(width)x\(height) context") }
    ctx.interpolationQuality = .high
    return ctx
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

// MARK: App icon — Apple's macOS grid: an 824-pt rounded square centred on a 1024-pt canvas.

func appIcon(size: Int) -> CGImage {
    let ctx = context(size, size)
    let k = CGFloat(size) / 1024
    let tile = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)
    // Soft drop shadow under the tile, as on Apple's own icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 20 * k,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(srgbRed: 0.99, green: 0.89, blue: 0.77, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(artwork, in: tile)
    return ctx.makeImage()!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(appIcon(size: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(appIcon(size: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }

// MARK: Menu-bar glyph — a solid silhouette, like the filled system icons beside it.
//
// The artwork is outline drawing; at 18 pt its strokes are ~1 px and read as faint. Instead:
// every enclosed region (head, body, tail, laptop) becomes solid, the outer outline merges into
// it, the artwork's inner lines become cut-out gaps between the parts, the face features become
// holes, and open strokes (the sound-wave) stay as heavy strokes.

let work = 1200
let workCtx = context(work, work)
workCtx.draw(artwork, in: CGRect(x: 0, y: 0, width: work, height: work))
let pixels = workCtx.data!.bindMemory(to: UInt8.self, capacity: work * work * 4)

// Tuning, in work pixels (artwork strokes are ~29 px at this size). Optional overrides:
//   swift scripts/make-icons.swift [source.png] [outlineReach] [gapWiden] [thicken]
func arg(_ index: Int, _ fallback: Int) -> Int {
    CommandLine.arguments.count > index ? Int(CommandLine.arguments[index]) ?? fallback : fallback
}
/// Ink this close to the outside counts as outline (solid); deeper ink is an inner line (gap).
let outlineReach = arg(2, 36)
/// How much wider the cut-out gaps and face holes are than the artwork's lines. 12 (with
/// thicken 4) is the variant approved for the menu bar: the parts separate clearly at 18 pt.
let gapWiden = arg(3, 12)
/// Final growth of the whole shape, which mainly thickens the sound-wave strokes.
let thicken = arg(4, 4)

// Ink: dark pixels of the artwork (the cream background is light).
var ink = [Bool](repeating: false, count: work * work)
for i in 0..<(work * work) {
    let r = Double(pixels[i * 4]), g = Double(pixels[i * 4 + 1]), b = Double(pixels[i * 4 + 2])
    let a = Double(pixels[i * 4 + 3])
    let luma = a > 0 ? (0.299 * r + 0.587 * g + 0.114 * b) / a : 1
    ink[i] = luma < 0.5
}

/// Square dilation (separable sliding window), O(pixels) regardless of radius.
func dilate(_ input: [Bool], _ radius: Int) -> [Bool] {
    guard radius > 0 else { return input }
    func pass(_ src: [Bool], horizontal: Bool) -> [Bool] {
        var out = [Bool](repeating: false, count: src.count)
        for line in 0..<work {
            var count = 0
            func at(_ i: Int) -> Bool { horizontal ? src[line * work + i] : src[i * work + line] }
            for i in 0..<min(radius, work) where at(i) { count += 1 }
            for i in 0..<work {
                if i + radius < work, at(i + radius) { count += 1 }
                if i - radius - 1 >= 0, at(i - radius - 1) { count -= 1 }
                out[horizontal ? line * work + i : i * work + line] = count > 0
            }
        }
        return out
    }
    return pass(pass(input, horizontal: true), horizontal: false)
}

// Outside: background reachable from the image border without crossing ink.
var outside = [Bool](repeating: false, count: work * work)
var stack: [Int] = []
for i in 0..<work {
    for p in [i, (work - 1) * work + i, i * work, i * work + work - 1] where !ink[p] && !outside[p] {
        outside[p] = true
        stack.append(p)
    }
}
while let p = stack.popLast() {
    let x = p % work, y = p / work
    for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= 0 && nx < work && ny >= 0 && ny < work {
        let n = ny * work + nx
        if !ink[n] && !outside[n] { outside[n] = true; stack.append(n) }
    }
}

let nearOutside = dilate(outside, outlineReach)
let innerLines = dilate((0..<(work * work)).map { ink[$0] && !nearOutside[$0] }, gapWiden)
var mask = [UInt8](repeating: 0, count: work * work)
let solid = dilate((0..<(work * work)).map { !outside[$0] && !innerLines[$0] }, thicken)
for i in 0..<(work * work) where solid[i] && !innerLines[i] { mask[i] = 255 }

// Crop to the ink's bounding box.
var (minX, minY, maxX, maxY) = (work, work, -1, -1)
for y in 0..<work { for x in 0..<work where mask[y * work + x] != 0 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
guard maxX >= minX else { fail("no ink found in artwork") }
let cropW = maxX - minX + 1, cropH = maxY - minY + 1

let glyphCtx = context(cropW, cropH)
let glyphPixels = glyphCtx.data!.bindMemory(to: UInt8.self, capacity: cropW * cropH * 4)
let rowBytes = glyphCtx.bytesPerRow
for y in 0..<cropH { for x in 0..<cropW {
    // The mask is in context memory order (row 0 = top), as is glyphCtx's buffer.
    let value = mask[(minY + y) * work + (minX + x)]
    let o = y * rowBytes + x * 4
    glyphPixels[o] = 0; glyphPixels[o + 1] = 0; glyphPixels[o + 2] = 0; glyphPixels[o + 3] = value
} }
let glyph = glyphCtx.makeImage()!

for (scale, suffix) in [(1, ""), (2, "@2x")] {
    let height = 18 * scale
    let width = Int((Double(cropW) / Double(cropH) * Double(height)).rounded())
    let ctx = context(width, height)
    ctx.draw(glyph, in: CGRect(x: 0, y: 0, width: width, height: height))
    writePNG(ctx.makeImage()!, to: resources.appendingPathComponent("MenuBarIcon\(suffix).png"))
}

print("wrote Resources/AppIcon.icns, Resources/MenuBarIcon.png, Resources/MenuBarIcon@2x.png")
