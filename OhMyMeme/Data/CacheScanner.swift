import Foundation

/// 缓存扫描：双重去重（文件名 + SHA-256），与桌面端 rescan_cache 一致
enum CacheScanner {
    static func scan() -> Int {
        let db = AppContext.shared.db
        let fm = FileManager.default
        let cacheDir = StoragePaths.cacheDir
        guard let enumerator = fm.enumerator(
            at: cacheDir,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var added = 0
        for case let url as URL in enumerator {
            guard !url.hasDirectoryPath else { continue }
            let name = url.lastPathComponent
            let ext = FileUtils.ext(fromName: name)
            guard FileUtils.allowedExt.contains(ext) else { continue }
            // 跳过由 WebP 动图自动生成的 GIF（同名 .webp 存在即为生成物）
            if ext == ".gif" {
                let stem = FileUtils.stem(fromName: name)
                if fm.fileExists(atPath: cacheDir.appendingPathComponent("\(stem).webp").path) {
                    continue
                }
            }
            // 双重去重
            if db.getByFilename(name) != nil { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let fhash = FileUtils.sha256(data)
            if db.getByHash(fhash) != nil { continue }
            let dims = ImageInfo.bounds(data)
            let mime = "image/\(ext.dropFirst())"
            var fileSize: Int64 = 0
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = (attrs[.size] as? NSNumber)?.int64Value {
                fileSize = size
            }
            db.addMeme(
                filename: name,
                fileHash: fhash,
                width: dims.w,
                height: dims.h,
                fileSize: fileSize,
                mimeType: mime,
                originalName: FileUtils.stem(fromName: name)
            )
            added += 1
        }
        return added
    }
}