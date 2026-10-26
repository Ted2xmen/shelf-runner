// Renders ShelfBridge.app's icon from design/icon/bridge-app-icon-1024.svg (see
// design/icon/README.md): 16, 32, 128, 256, 512 pt at @1x and @2x into build/AppIcon.iconset,
// then build/AppIcon.icns with iconutil. AppKit's own SVG renderer, sRGB PNGs; modelled on
// Shelf's scripts/make-brand-assets.swift. Same input, same output. Run from the repo root:
//
//   swift scripts/make-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("design/icon/bridge-app-icon-1024.svg")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let icns = root.appendingPathComponent("build/AppIcon.icns")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-app-icon: \(message)\n".utf8))
    exit(1)
}

/// The SVG without its <metadata> block (provenance data, not drawing).
func stripped(_ svg: String) -> String {
    guard let start = svg.range(of: "<metadata>"), let end = svg.range(of: "</metadata>") else { return svg }
    var text = svg
    text.removeSubrange(start.lowerBound..<end.upperBound)
    return text.replacingOccurrences(of: " xmlns:c2pa=\"http://c2pa.org/manifest\"", with: "")
}

func png(from svg: String, pixels: Int) -> Data {
    guard let image = NSImage(data: Data(svg.utf8)) else { fail("AppKit cannot read the icon SVG") }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("cannot make a \(pixels) px bitmap") }
    context.interpolationQuality = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let cg = context.makeImage(), let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    else { fail("cannot encode a \(pixels) px PNG") }
    return data
}

guard let raw = try? String(contentsOf: source, encoding: .utf8) else { fail("cannot read \(source.path)") }
let svg = stripped(raw)
try? FileManager.default.removeItem(at: iconset)
do { try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true) } catch { fail("\(error)") }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let url = iconset.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
        do { try png(from: svg, pixels: points * scale).write(to: url) } catch { fail("cannot write \(url.path): \(error)") }
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
do { try p.run(); p.waitUntilExit() } catch { fail("iconutil: \(error)") }
guard p.terminationStatus == 0 else { fail("iconutil exited \(p.terminationStatus)") }
print(icns.path)
