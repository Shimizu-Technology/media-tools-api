#!/usr/bin/env swift
// Generates the Media Tools app icon: Ledger's two quote marks on ink blue.
// Run from the repository root: swift ios/scripts/generate-icon.swift
//
// Writes:
//   ios/MediaTools/MediaTools/Assets.xcassets/AppIcon.appiconset/icon_1024.png
//   ios/MediaTools/MediaToolsShared/Ledger.xcassets/AppMark.imageset/app-mark.png
//
// App Store Connect rejects an icon with an alpha channel, so this draws into an
// opaque bitmap (`noneSkipLast`). Check with:
//   sips -g hasAlpha ios/MediaTools/MediaTools/Assets.xcassets/AppIcon.appiconset/icon_1024.png

import AppKit

let size = 1024
let inkBlue = CGColor(srgbRed: 0x1F / 255, green: 0x4F / 255, blue: 0x9E / 255, alpha: 1)
let paper = CGColor(srgbRed: 0xF7 / 255, green: 0xF5 / 255, blue: 0xF0 / 255, alpha: 1)

/// One quote mark: a round bowl with a tail sweeping up and to the right. The
/// geometry comes from the Ledger mockup, in its y-down coordinates.
func quoteMark(centerX bx: CGFloat, centerY by: CGFloat, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addEllipse(in: CGRect(x: bx - r, y: by - r, width: r * 2, height: r * 2))
    path.move(to: CGPoint(x: bx - r, y: by))
    path.addCurve(
        to: CGPoint(x: bx + 0.62 * r, y: by - 2.25 * r),
        control1: CGPoint(x: bx - r, y: by - 1.15 * r),
        control2: CGPoint(x: bx - 0.15 * r, y: by - 2.05 * r)
    )
    path.addLine(to: CGPoint(x: bx + 0.8 * r, y: by - 1.92 * r))
    path.addCurve(
        to: CGPoint(x: bx + 0.12 * r, y: by - 0.55 * r),
        control1: CGPoint(x: bx + 0.25 * r, y: by - 1.62 * r),
        control2: CGPoint(x: bx + 0.02 * r, y: by - 1.05 * r)
    )
    path.closeSubpath()
    return path
}

func drawIcon(pixels: Int) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { fatalError("Could not create the bitmap") }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    // Draw in the mockup's 1024-unit, y-down space.
    let scale = CGFloat(pixels) / CGFloat(size)
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)

    context.setFillColor(inkBlue)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))

    context.setFillColor(paper)
    for mark in [
        quoteMark(centerX: 352, centerY: 593, radius: 130),
        quoteMark(centerX: 672, centerY: 593, radius: 130),
    ] {
        context.addPath(mark)
        context.fillPath()
    }

    guard let image = context.makeImage() else { fatalError("Could not finish the bitmap") }
    return image
}

func writePNG(_ image: CGImage, to path: String) {
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(path)")
    }
    do {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        fatalError("Could not write \(path): \(error)")
    }
    print("Wrote \(path)")
}

writePNG(
    drawIcon(pixels: 1024),
    to: "ios/MediaTools/MediaTools/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
)
// The extensions cannot load AppIcon, so sign-in and the share card use this copy.
writePNG(
    drawIcon(pixels: 256),
    to: "ios/MediaTools/MediaToolsShared/Ledger.xcassets/AppMark.imageset/app-mark.png"
)
