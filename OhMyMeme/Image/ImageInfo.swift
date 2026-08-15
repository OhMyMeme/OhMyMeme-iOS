import Foundation
import ImageIO
import UIKit
import SDWebImage
import SDWebImageWebPCoder

enum ImageInfo {
    /// 只读宽高（对应桌面端 PIL 尺寸读取 / 安卓 BitmapFactory bounds）
    static func bounds(_ data: Data) -> (w: Int, h: Int) {
        if FileUtils.detectExt(data) == ".webp" {
            if let img = SDImageAWebPCoder.shared.decodedImage(with: data, options: nil) {
                return (Int(img.size.width), Int(img.size.height))
            }
            return (0, 0)
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return (0, 0) }
        return (w, h)
    }

    /// 生成缩略图（PNG/JPEG/GIF 用 ImageIO 高效降采样；WebP 经 libwebp 解码后缩放）
    static func thumbnailImage(_ data: Data, size: Int) -> UIImage? {
        if FileUtils.detectExt(data) == ".webp" {
            guard let img = SDImageAWebPCoder.shared.decodedImage(with: data, options: nil) else {
                return nil
            }
            return scale(img, to: size)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size * 2,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func scale(_ image: UIImage, to size: Int) -> UIImage? {
        let target = CGSize(width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}