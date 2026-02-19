#!/usr/bin/env swift
// Generates a 1024x1024 app icon for Media Tools.
// Run: swift ios/scripts/generate-icon.swift
// Output: ios/MediaTools/MediaTools/Assets.xcassets/AppIcon.appiconset/icon_1024.png

import AppKit

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()

// Background: dark teal gradient
let ctx = NSGraphicsContext.current!.cgContext

// Rounded rect clip (iOS icon shape is applied by system, but nice for preview)
let bgColor = NSColor(red: 0.05, green: 0.12, blue: 0.14, alpha: 1.0)
let accentColor = NSColor(red: 0.184, green: 0.620, blue: 0.561, alpha: 1.0) // teal

bgColor.setFill()
NSRect(origin: .zero, size: size).fill()

// Draw waveform bars
let barCount = 7
let barWidth: CGFloat = 60
let barSpacing: CGFloat = 24
let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
let startX = (1024 - totalWidth) / 2
let centerY: CGFloat = 512

let heights: [CGFloat] = [180, 320, 260, 420, 280, 360, 200]

for i in 0..<barCount {
    let x = startX + CGFloat(i) * (barWidth + barSpacing)
    let h = heights[i]
    let y = centerY - h / 2
    let rect = NSRect(x: x, y: y, width: barWidth, height: h)
    let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
    accentColor.setFill()
    path.fill()
}

image.unlockFocus()

// Save
let outputPath = "ios/MediaTools/MediaTools/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
if let tiffData = image.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiffData),
   let pngData = bitmap.representation(using: .png, properties: [:]) {
    try! pngData.write(to: URL(fileURLWithPath: outputPath))
    print("✅ Icon saved to \(outputPath)")
} else {
    print("❌ Failed to generate icon")
}
