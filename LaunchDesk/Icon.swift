import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16,32,64,128,256,512,1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size)
    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s-inset*2, height: s-inset*2)
    let base = NSBezierPath(roundedRect: rect, xRadius: s*0.20, yRadius: s*0.20)
    NSGradient(starting: NSColor(calibratedRed: 0.23, green: 0.43, blue: 0.90, alpha: 1),
               ending: NSColor(calibratedRed: 0.14, green: 0.23, blue: 0.62, alpha: 1))!.draw(in: base, angle: 80)
    NSColor.white.setStroke()
    let clock = NSBezierPath(ovalIn: NSRect(x:s*0.23,y:s*0.27,width:s*0.54,height:s*0.54))
    clock.lineWidth = s*0.047
    clock.stroke()
    let hands = NSBezierPath()
    hands.move(to:NSPoint(x:s*0.5,y:s*0.69)); hands.line(to:NSPoint(x:s*0.5,y:s*0.54)); hands.line(to:NSPoint(x:s*0.62,y:s*0.47))
    hands.lineWidth = s*0.047; hands.lineCapStyle = .round; hands.lineJoinStyle = .round; hands.stroke()
    let pill = NSBezierPath(roundedRect:NSRect(x:s*0.38,y:s*0.15,width:s*0.24,height:s*0.068),xRadius:s*0.034,yRadius:s*0.034)
    NSColor(calibratedRed:0.52,green:0.91,blue:0.83,alpha:1).setFill(); pill.fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
    let png = bitmap.representation(using:.png,properties:[:])!
    let name: String
    if size == 1024 { name = "icon_512x512@2x.png" }
    else { name = "icon_\(size)x\(size).png" }
    try png.write(to:folder.appendingPathComponent(name))
    if size >= 32 && size <= 512 {
        try png.write(to:folder.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png"))
    }
}
