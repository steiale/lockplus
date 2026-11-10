// Renders the system-masked (macOS 26 squircle) app icon into an .iconset directory, for the DMG volume icon.
// Usage: swiftc make-volume-icon.swift -o <bin> && <bin> <LockPlus.app> <out.iconset>; then iconutil -c icns.
// release.sh runs it on the built app at every release, so the volume icon can't drift from AppIcon.
// Every failure is an error with a message and exit status 1 (no force unwraps).
import AppKit

struct IconError: Error, CustomStringConvertible {
    let description: String
}

func run() throws {
    let a = CommandLine.arguments
    guard a.count == 3 else { throw IconError(description: "usage: make-volume-icon <LockPlus.app> <out.iconset>") }
    let app = a[1], out = a[2]
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: app, isDirectory: &isDir), isDir.boolValue, app.hasSuffix(".app") else {
        throw IconError(description: "not an app bundle: \(app)")
    }
    let img = NSWorkspace.shared.icon(forFile: app)
    guard img.isValid, img.size.width > 0 else { throw IconError(description: "no icon for \(app)") }
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let sizes = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                 ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
    for (name, s) in sizes {
        guard let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: r) else {
            throw IconError(description: "can't create a \(s)×\(s) bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        img.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = r.representation(using: .png, properties: [:]) else { throw IconError(description: "PNG encoding failed (\(name))") }
        try png.write(to: URL(fileURLWithPath: out).appending(path: "icon_\(name).png"))
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("make-volume-icon: \(error)\n".utf8))
    exit(1)
}
