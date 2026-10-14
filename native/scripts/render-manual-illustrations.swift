import AppKit
import Foundation

struct Guide: Decodable {
    let chapter: String
    let name: String
    let source: String
    let title: String
    let guides: [String]
    let points: [[Double]]
    let crop: [Double]
}
// Run from repository root: swift native/scripts/render-manual-illustrations.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("native")
let entries = try JSONDecoder().decode([Guide].self, from: Data(contentsOf: root.appendingPathComponent("scripts/manual-illustrations.json")))
let destination = root.appendingPathComponent("Sources/TabbyNative/Resources/AIManual")
let accent = NSColor(srgbRed: 0.18, green: 0.57, blue: 0.96, alpha: 1)
let text = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.18, alpha: 1)
let muted = NSColor(srgbRed: 0.48, green: 0.54, blue: 0.57, alpha: 1)
func label(_ value: String, _ rect: NSRect, size: CGFloat, bold: Bool = false, color: NSColor = .black) {
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
    (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color, .paragraphStyle: paragraph])
}
for item in entries {
    guard let picture = NSImage(contentsOf: root.appendingPathComponent("Documentation/ManualScreenshots/" + item.source)) else { fatalError("Missing screenshot: " + item.source) }
    precondition(item.guides.count == item.points.count && item.guides.count == 3)
    let crop = NSRect(x: picture.size.width * item.crop[0], y: picture.size.height * (1 - item.crop[1] - item.crop[3]), width: picture.size.width * item.crop[2], height: picture.size.height * item.crop[3])
    let scale = min(820 / crop.width, 1000 / crop.height)
    let photoSize = NSSize(width: crop.width * scale, height: crop.height * scale)
    let width: CGFloat = 860, photoTop: CGFloat = 82
    let height = photoTop + photoSize.height + 180
    let output = NSImage(size: NSSize(width: width, height: height))
    output.lockFocusFlipped(true)
    NSColor.white.setFill(); NSRect(origin: .zero, size: output.size).fill()
    label(item.title, NSRect(x: 24, y: 16, width: 812, height: 30), size: 21, bold: true, color: text)
    label("实际界面 · 示例数据 ｜ 按图中编号完成操作", NSRect(x: 24, y: 50, width: 812, height: 20), size: 12, color: muted)
    let photo = NSRect(x: (width - photoSize.width) / 2, y: photoTop, width: photoSize.width, height: photoSize.height)
    picture.draw(in: photo, from: crop, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    for (index, point) in item.points.enumerated() {
        let center = NSPoint(x: photo.minX + point[0] * photo.width, y: photo.minY + point[1] * photo.height)
        let badge = NSRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28)
        NSColor.white.setStroke(); let outline = NSBezierPath(ovalIn: badge.insetBy(dx: -2, dy: -2)); outline.lineWidth = 3; outline.stroke()
        accent.setFill(); NSBezierPath(ovalIn: badge).fill()
        let number = String(index + 1) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.white]
        let size = number.size(withAttributes: attrs)
        number.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
        let x = CGFloat(index) * 276 + 20, y = photo.maxY + 18
        NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 268, height: 136), xRadius: 8, yRadius: 8).fill()
        label("\(index + 1)", NSRect(x: x + 14, y: y + 12, width: 24, height: 22), size: 18, bold: true, color: accent)
        label(item.guides[index], NSRect(x: x + 14, y: y + 43, width: 240, height: 86), size: 15, color: text)
    }
    output.unlockFocus()
    guard let tiff = output.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Screenshot encoding failed") }
    try png.write(to: destination.appendingPathComponent(item.name))
    print(item.name)
}
