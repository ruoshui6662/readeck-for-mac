import AppKit
let size = NSSize(width: 660, height: 320)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedWhite: 0.975, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
let arrow = NSBezierPath()
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedWhite: 0.65, alpha: 0.85).setStroke()
arrow.move(to: NSPoint(x: 300, y: 160))
arrow.line(to: NSPoint(x: 357, y: 160))
arrow.move(to: NSPoint(x: 347, y: 169))
arrow.line(to: NSPoint(x: 357, y: 160))
arrow.line(to: NSPoint(x: 347, y: 151))
arrow.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
