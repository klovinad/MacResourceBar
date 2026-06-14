#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconSourceURL = root.appendingPathComponent("Resources/Brand/AppIconSource.png")
let cleanedIconURL = root.appendingPathComponent("Resources/Brand/AppIconClean.png")
let iconDirectory = root.appendingPathComponent("NetworkMenuMonitor/Assets.xcassets/AppIcon.appiconset")
let dmgAssetsDirectory = root.appendingPathComponent("Resources/DMG")
let backgroundURL = dmgAssetsDirectory.appendingPathComponent("background.png")

try FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: dmgAssetsDirectory, withIntermediateDirectories: true)

func savePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "MacResourceBarAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    try png.write(to: url)
}

func resizedImage(from image: NSImage, size: CGFloat) -> NSImage {
    let resized = NSImage(size: NSSize(width: size, height: size))
    resized.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    resized.unlockFocus()
    return resized
}

func cleanedAppIcon(from image: NSImage) -> NSImage {
    let size = NSSize(width: 1024, height: 1024)
    let cleaned = NSImage(size: size)
    cleaned.lockFocus()
    defer { cleaned.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()

    let iconRect = NSRect(x: 34, y: 34, width: 956, height: 956)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: iconRect, xRadius: 160, yRadius: 160).addClip()
    image.draw(
        in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
        from: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height),
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    return cleaned
}

func makeDMGBackground() -> NSImage {
    let size = NSSize(width: 640, height: 500)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.84, green: 0.91, blue: 1.0, alpha: 1)
    ])
    gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 12)

    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 0.92)
    ]
    let subtitleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 0.72)
    ]
    let arrowAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 52, weight: .light),
        .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 0.32)
    ]
    let footerAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 0.62)
    ]

    "MacResourceBar".draw(at: NSPoint(x: 40, y: 424), withAttributes: titleAttributes)
    "Drag the app into Applications".draw(at: NSPoint(x: 42, y: 398), withAttributes: subtitleAttributes)
    "->".draw(at: NSPoint(x: 286, y: 232), withAttributes: arrowAttributes)
    "Menu bar CPU, RAM, disk, network and per-app process monitor.".draw(
        at: NSPoint(x: 40, y: 34),
        withAttributes: footerAttributes
    )

    return image
}

guard let sourceIcon = NSImage(contentsOf: iconSourceURL) else {
    throw NSError(
        domain: "MacResourceBarAssets",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Missing icon source at \(iconSourceURL.path)"]
    )
}
let appIcon = cleanedAppIcon(from: sourceIcon)
try savePNG(appIcon, to: cleanedIconURL)

let outputs: [(String, CGFloat)] = [
    ("icon_16.png", 16),
    ("icon_16x2.png", 32),
    ("icon_32.png", 32),
    ("icon_32x2.png", 64),
    ("icon_128.png", 128),
    ("icon_128x2.png", 256),
    ("icon_256.png", 256),
    ("icon_256x2.png", 512),
    ("icon_512.png", 512),
    ("icon_512x2.png", 1024)
]

for (filename, size) in outputs {
    try savePNG(resizedImage(from: appIcon, size: size), to: iconDirectory.appendingPathComponent(filename))
}

try savePNG(makeDMGBackground(), to: backgroundURL)
print("Generated app icons from \(iconSourceURL.path) and \(backgroundURL.path)")
