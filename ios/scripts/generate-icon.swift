#!/usr/bin/env swift
// Generates the Media Tools app icon from the geometry in ios/design/app-icon.svg:
// white sound bars rising over a horizon, on the amber to coral to red gradient.
// Run from the repository root: swift ios/scripts/generate-icon.swift
//
// Writes:
//   ios/MediaTools/MediaTools/Assets.xcassets/AppIcon.appiconset/icon_1024.png
//   ios/MediaTools/MediaToolsShared/Theme.xcassets/AppMark.imageset/app-mark.png
//
// App Store Connect rejects an icon with an alpha channel, so this draws into an
// opaque bitmap (`noneSkipLast`). Check with:
//   sips -g hasAlpha ios/MediaTools/MediaTools/Assets.xcassets/AppIcon.appiconset/icon_1024.png

import AppKit

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

func drawIcon(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { fatalError("Could not create the bitmap") }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    // Draw in the SVG's 100-unit, y-down space.
    let scale = CGFloat(pixels) / 100
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)

    guard let gradient = CGGradient(
        colorsSpace: space,
        colors: [color(0xF59A3C), color(0xDC4F22), color(0xAE2733)] as CFArray,
        locations: [0, 0.55, 1]
    ) else { fatalError("Could not create the gradient") }
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 100, y: 100),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.setLineCap(.round)
    context.setLineWidth(7.5)
    for (x, top) in [(22.0, 58.0), (36.0, 44.0), (50.0, 30.0), (64.0, 44.0), (78.0, 58.0)] {
        context.move(to: CGPoint(x: x, y: 66))
        context.addLine(to: CGPoint(x: x, y: top))
    }
    context.strokePath()

    context.setLineWidth(6)
    context.move(to: CGPoint(x: 14, y: 78))
    context.addLine(to: CGPoint(x: 86, y: 78))
    context.strokePath()

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
    to: "ios/MediaTools/MediaToolsShared/Theme.xcassets/AppMark.imageset/app-mark.png"
)
