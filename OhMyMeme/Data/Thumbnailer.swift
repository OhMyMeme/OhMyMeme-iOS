import Foundation
import UIKit

enum Thumbnailer {
    static let thumbSize = 150

    /// 缩略图命名 {meme_id}_{size}.png（与桌面端/安卓端一致）
    static func thumbnailURL(for memeId: Int64) -> URL {
        StoragePaths.thumbnailDir.appendingPathComponent("\(memeId)_\(thumbSize).png")
    }

    /// 缓存根目录直接路径（用于网格高频读取，不做递归遍历）
    static func cacheFileURL(_ filename: String) -> URL {
        StoragePaths.cacheDir.appendingPathComponent(filename)
    }

    /// 对应桌面端 _find_meme_file：先查缓存根目录，再递归遍历
    static func findMemeFile(_ filename: String) -> URL? {
        let fm = FileManager.default
        let direct = StoragePaths.cacheDir.appendingPathComponent(filename)
        if fm.fileExists(atPath: direct.path) { return direct }
        guard let enumerator = fm.enumerator(
            at: StoragePaths.cacheDir,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for case let url as URL in enumerator {
            if !url.hasDirectoryPath && url.lastPathComponent == filename {
                return url
            }
        }
        return nil
    }

    /// 确保缩略图存在并返回其 URL（存在即复用，与桌面端一致）
    static func ensureThumbnail(for meme: Meme) -> URL? {
        let url = thumbnailURL(for: meme.id)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let src = findMemeFile(meme.filename),
              let data = try? Data(contentsOf: src),
              let img = ImageInfo.thumbnailImage(data, size: thumbSize),
              let png = img.pngData()
        else { return nil }
        try? png.write(to: url)
        return url
    }
}