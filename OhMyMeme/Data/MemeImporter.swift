import Foundation

enum MemeImporter {
    /// 把内存字节按哈希去重后入库（对应桌面端 _do_import 的导入逻辑）
    static func importData(
        _ data: Data,
        originalName: String,
        ext: String? = nil,
        db: MemeDb = AppContext.shared.db
    ) -> Bool {
        let realExt = ext ?? FileUtils.detectExt(data)
        guard !realExt.isEmpty else { return false }

        // 先校验内容为合法可解码图片（宽高 > 0），通过后才落盘，杜绝孤儿缓存文件
        let dims = ImageInfo.bounds(data)
        guard dims.w > 0, dims.h > 0 else { return false }

        let fhash = FileUtils.sha256(data)
        guard db.getByHash(fhash) == nil else { return false }

        let dstName = "\(String(fhash.prefix(16)))\(realExt)"
        let dst = StoragePaths.cacheDir.appendingPathComponent(dstName)
        do {
            try data.write(to: dst)
        } catch {
            return false
        }

        let mime = "image/\(realExt.dropFirst())"
        let oname = originalName.contains(".") ? (originalName as NSString).deletingPathExtension : originalName
        db.addMeme(
            filename: dstName,
            fileHash: fhash,
            width: dims.w,
            height: dims.h,
            fileSize: Int64(data.count),
            mimeType: mime,
            originalName: oname
        )
        return true
    }

    static func importFile(
        at url: URL,
        originalName: String,
        db: MemeDb = AppContext.shared.db
    ) -> Bool {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else { return false }
        return importData(data, originalName: originalName, db: db)
    }

    static func isValidImage(_ data: Data) -> Bool {
        guard !FileUtils.detectExt(data).isEmpty else { return false }
        let dims = ImageInfo.bounds(data)
        return dims.w > 0 && dims.h > 0
    }
}