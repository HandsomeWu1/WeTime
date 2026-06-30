import AppKit
import Foundation

// 用法: swift icon_polish.swift input.png output.png
guard CommandLine.arguments.count >= 3 else {
    print("用法: swift icon_polish.swift <input.png> <output.png>")
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

guard let src = NSImage(contentsOfFile: inputPath) else {
    print("❌ 无法读取: \(inputPath)")
    exit(1)
}

let canvasSize: CGFloat = 1024
let inset: CGFloat = 100               // 四周留白
let cornerRadius: CGFloat = 185        // 圆角半径
let contentSize = canvasSize - inset * 2

let result = NSImage(size: NSSize(width: canvasSize, height: canvasSize))
result.lockFocus()

// 1) 画圆角矩形作为背景遮罩区域
let rect = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
path.addClip()

// 2) 透明背景（不填充任何颜色）
// NSColor.white.setFill()
// rect.fill()

// 3) 把源图等比缩放到内容区中央
let srcSize = src.size
let scale = min(contentSize / srcSize.width, contentSize / srcSize.height)
let drawW = srcSize.width * scale
let drawH = srcSize.height * scale
let drawRect = NSRect(
    x: (canvasSize - drawW) / 2,
    y: (canvasSize - drawH) / 2,
    width: drawW,
    height: drawH
)
src.draw(in: drawRect)

result.unlockFocus()

// 导出 PNG
guard let tiff = result.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("❌ 编码失败")
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
print("✅ 输出: \(outputPath)")
