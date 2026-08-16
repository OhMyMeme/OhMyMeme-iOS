import Foundation
import UIKit
import ImageIO
import SDWebImage
import SDWebImageWebPCoder

/// 复制/分享前处理：对应桌面端 clipboard_util.py convert_image_mode_1/2。
/// - mode 1：静态图超限时缩放到 copy_resize_max 并存为 WebP（q90）
/// - mode 2：静态图超限时转为普通 GIF（256 色）
/// - mode 3：隐写 GIF（STG3）—— 依赖 XZ/LZMA2，排期后续引入 vendored liblzma 后实现
/// 动图 / 未超限 / 处理失败均返回 nil，调用方回退原图直发。
enum MemeCopyProcessor {

    struct Result {
        let url: URL
        let mimeType: String
    }

    /// 复制/分享前处理（应在后台队列调用）
    static func process(meme: Meme) -> Result? {
        let cfg = AppContext.shared.config
        let mode = cfg.int("copy_resize_mode")
        guard mode == 1 || mode == 2 else { return nil }
        guard let src = Thumbnailer.findMemeFile(meme.filename) else { return nil }
        guard let data = try? Data(contentsOf: src) else { return nil }
        if FileUtils.isAnimated(data) { return nil }
        let dims = ImageInfo.bounds(data)
        guard dims.w > 0, dims.h > 0 else { return nil }
        let rawMax = cfg.int("copy_resize_max")
        let maxSide = rawMax > 0 ? rawMax : 200
        guard max(dims.w, dims.h) > maxSide else { return nil }
        switch mode {
        case 1: return toWebp(data, maxSide: maxSide)
        case 2: return toGif(data, w: dims.w, h: dims.h)
        default: return nil
        }
    }

    private static func toWebp(_ data: Data, maxSide: Int) -> Result? {
        guard let img = scaledImage(data, maxSide: maxSide) else { return nil }
        guard let out = SDImageAWebPCoder.shared.encodedData(
            with: img, format: .webP, options: [.encodeCompressionQuality: 0.9]
        ) else { return nil }
        return writeTemp(out, ext: "webp", mime: "image/webp")
    }

    private static func toGif(_ data: Data, w: Int, h: Int) -> Result? {
        guard w * h <= 32_000_000,
              let img = fullImage(data),
              let cg = img.cgImage
        else { return nil }
        var rgba = rgbaBytes(from: cg, width: w, height: h)
        guard rgba.count == w * h * 4 else { return nil }
        unPremultiply(&rgba)
        let gif = GifEncoder.encode(rgba: rgba, width: w, height: h)
        return writeTemp(Data(gif), ext: "gif", mime: "image/gif")
    }

    // MARK: - 图像辅助

    /// ImageIO 高效降采样解码，长边收敛到 maxSide（保持比例），避免超大图整幅解码
    private static func scaledImage(_ data: Data, maxSide: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func fullImage(_ data: Data) -> UIImage? {
        if FileUtils.detectExt(data) == ".webp" {
            return SDImageAWebPCoder.shared.decodedImage(with: data, options: nil)
        }
        return UIImage(data: data)
    }

    /// CGImage → 未预乘 RGBA 字节（先画入预乘 RGBA 缓冲，再反预乘，还原文件真实 RGB，对齐 Pillow / 安卓）
    private static func rgbaBytes(from cg: CGImage, width w: Int, height h: Int) -> [UInt8] {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let ctx = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: colorSpace, bitmapInfo: info.rawValue
        ) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }

    /// 反预乘（与安卓 MemeCopyProcessor.bitmapToRgba 一致）
    private static func unPremultiply(_ rgba: inout [UInt8]) {
        let n = rgba.count / 4
        var i = 0
        for _ in 0..<n {
            var a = Int(rgba[i + 3])
            var r = Int(rgba[i])
            var g = Int(rgba[i + 1])
            var b = Int(rgba[i + 2])
            if a >= 1 && a <= 254 {
                r = min(255, r * 255 / a)
                g = min(255, g * 255 / a)
                b = min(255, b * 255 / a)
            }
            rgba[i] = UInt8(r)
            rgba[i + 1] = UInt8(g)
            rgba[i + 2] = UInt8(b)
            rgba[i + 3] = UInt8(a)
            i += 4
        }
    }

    private static func writeTemp(_ data: Data, ext: String, mime: String) -> Result? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("copy_\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url)
            return Result(url: url, mimeType: mime)
        } catch {
            return nil
        }
    }
}