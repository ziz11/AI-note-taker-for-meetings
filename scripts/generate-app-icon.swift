#!/usr/bin/env swift

import AppKit
import Foundation

enum AppIconGeneratorError: LocalizedError {
    case invalidArguments
    case bitmapCreationFailed
    case contextCreationFailed
    case pngEncodingFailed
    case resizeFailed(fileName: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Usage: swift scripts/generate-app-icon.swift <AppIcon.appiconset-directory>"
        case .bitmapCreationFailed:
            return "Could not allocate the 1024 × 1024 icon bitmap."
        case .contextCreationFailed:
            return "Could not create an AppKit drawing context."
        case .pngEncodingFailed:
            return "Could not encode the master icon as PNG."
        case .resizeFailed(let fileName, let status):
            return "sips failed to generate \(fileName) with exit status \(status)."
        }
    }
}

struct IconVariant {
    let fileName: String
    let pixels: Int
}

let variants = [
    IconVariant(fileName: "icon_16x16.png", pixels: 16),
    IconVariant(fileName: "icon_16x16@2x.png", pixels: 32),
    IconVariant(fileName: "icon_32x32.png", pixels: 32),
    IconVariant(fileName: "icon_32x32@2x.png", pixels: 64),
    IconVariant(fileName: "icon_128x128.png", pixels: 128),
    IconVariant(fileName: "icon_128x128@2x.png", pixels: 256),
    IconVariant(fileName: "icon_256x256.png", pixels: 256),
    IconVariant(fileName: "icon_256x256@2x.png", pixels: 512),
    IconVariant(fileName: "icon_512x512.png", pixels: 512),
    IconVariant(fileName: "icon_512x512@2x.png", pixels: 1024),
]

func color(red: Int, green: Int, blue: Int) -> NSColor {
    NSColor(
        calibratedRed: CGFloat(red) / 255,
        green: CGFloat(green) / 255,
        blue: CGFloat(blue) / 255,
        alpha: 1
    )
}

func polygon(_ points: [CGPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    guard let first = points.first else {
        return path
    }
    path.move(to: first)
    for point in points.dropFirst() {
        path.line(to: point)
    }
    path.close()
    path.lineJoinStyle = .round
    return path
}

func drawFace(
    points: [CGPoint],
    fill: NSColor,
    seam: NSColor
) {
    let path = polygon(points)
    fill.setFill()
    path.fill()
    seam.setStroke()
    path.lineWidth = 14
    path.stroke()
}

func makeMasterPNG() throws -> Data {
    let size = 1024
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw AppIconGeneratorError.bitmapCreationFailed
    }
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw AppIconGeneratorError.contextCreationFailed
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    graphicsContext.cgContext.setShouldAntialias(true)
    graphicsContext.cgContext.interpolationQuality = .high

    let graphite = color(red: 32, green: 36, blue: 36)
    graphite.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: size, height: size)).fill()

    let top = CGPoint(x: 512, y: 744)
    let left = CGPoint(x: 296, y: 624)
    let center = CGPoint(x: 512, y: 504)
    let right = CGPoint(x: 728, y: 624)
    let bottomLeft = CGPoint(x: 296, y: 384)
    let bottom = CGPoint(x: 512, y: 264)
    let bottomRight = CGPoint(x: 728, y: 384)

    drawFace(
        points: [top, right, center, left],
        fill: color(red: 225, green: 189, blue: 141),
        seam: graphite
    )
    drawFace(
        points: [left, center, bottom, bottomLeft],
        fill: color(red: 212, green: 171, blue: 120),
        seam: graphite
    )
    drawFace(
        points: [center, right, bottomRight, bottom],
        fill: color(red: 198, green: 150, blue: 98),
        seam: graphite
    )

    graphicsContext.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw AppIconGeneratorError.pngEncodingFailed
    }
    return png
}

func resize(
    source: URL,
    destination: URL,
    pixels: Int
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = [
        "--resampleHeightWidth",
        String(pixels),
        String(pixels),
        source.path,
        "--out",
        destination.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw AppIconGeneratorError.resizeFailed(
            fileName: destination.lastPathComponent,
            status: process.terminationStatus
        )
    }
}

guard CommandLine.arguments.count == 2 else {
    throw AppIconGeneratorError.invalidArguments
}

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments[1],
    isDirectory: true
).standardizedFileURL
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let masterVariant = variants.first { $0.pixels == 1024 }!
let masterURL = outputDirectory.appendingPathComponent(masterVariant.fileName)
try makeMasterPNG().write(to: masterURL, options: .atomic)

for variant in variants where variant.pixels != 1024 {
    try resize(
        source: masterURL,
        destination: outputDirectory.appendingPathComponent(variant.fileName),
        pixels: variant.pixels
    )
}

print("Generated \(variants.count) app icon assets in \(outputDirectory.path)")
