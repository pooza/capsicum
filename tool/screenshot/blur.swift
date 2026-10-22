// 画像の矩形の中だけを強くぼかす（ストア用スクリーンショットの写り込み対策）。
//   blur <入力.png> <出力.png> <x> <y> <幅> <高さ> [半径]
// 座標は画素・左上原点。
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count >= 7, let x = Double(a[3]), let y = Double(a[4]), let w = Double(a[5]), let h = Double(a[6]) else {
    print("usage: blur in.png out.png x y w h [radius]")
    exit(2)
}
let radius = a.count >= 8 ? Double(a[7]) ?? 60 : 60
guard let src = CIImage(contentsOf: URL(fileURLWithPath: a[1])) else { print("read failed"); exit(1) }
let H = src.extent.height
// CoreImage は左下原点なので y を反転する
let rect = CGRect(x: x, y: H - y - h, width: w, height: h)
let blurred = src.clampedToExtent()
    .applyingGaussianBlur(sigma: radius)
    .cropped(to: rect)
let out = blurred.composited(over: src).cropped(to: src.extent)
let ctx = CIContext()
guard let cg = ctx.createCGImage(out, from: src.extent),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    print("write failed"); exit(1)
}
CGImageDestinationAddImage(dest, cg, nil)
CGImageDestinationFinalize(dest)
print("ok")
