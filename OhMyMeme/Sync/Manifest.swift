import Foundation

/// 远端同步索引清单（对齐桌面端 src/manifest.py 与安卓端 CloudSync.kt）
enum Manifest {
    static let indexFilename = "meme-index.json"
    static let remoteMemeDir = "memes"
    static let manifestVersion = 3

    /// 校验远端文件名，拒绝路径穿越与绝对路径（与 lan.py _safe_fname / CloudSync 一致）
    static func isSafeRemoteFname(_ name: String) -> Bool {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.hasPrefix("."),
              !name.hasPrefix("/"),
              !name.hasPrefix("\\"),
              !name.hasPrefix("~"),
              !name.hasPrefix(".."),
              !name.contains("/"),
              !name.contains("\\")
        else { return false }
        return true
    }

    /// 从数据库重建完整索引（对齐 manifest.py build）
    static func buildManifest(db: MemeDb) -> [String: Any] {
        var memes: [[String: Any]] = []
        for m in db.getAll(offset: 0, limit: Int.max) {
            var entry: [String: Any] = [
                "filename": m.filename,
                "name": m.originalName.isEmpty ? FileUtils.stem(fromName: m.filename) : m.originalName,
                "sha256": m.fileHash,
                "file_size": m.fileSize
            ]
            let cacheFile = StoragePaths.cacheDir.appendingPathComponent(m.filename)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
               let mtime = attrs[.modificationDate] as? Date {
                entry["mtime"] = String(Int(mtime.timeIntervalSince1970))
            }
            memes.append(entry)
        }
        return [
            "version": manifestVersion,
            "memes": memes,
            "collections": buildCollectionTree(db: db, parentId: nil)
        ]
    }

    private static func buildCollectionTree(db: MemeDb, parentId: Int64?) -> [[String: Any]] {
        var arr: [[String: Any]] = []
        for c in db.getCollections() {
            let pid = c.parentId ?? 0
            if parentId == nil {
                if pid != 0 { continue }
            } else {
                if pid != parentId { continue }
            }
            let members = db.search(collectionId: c.id, limit: Int.max)
            let filenames = members.map { $0.filename }
            let children = buildCollectionTree(db: db, parentId: c.id)
            if filenames.isEmpty && children.isEmpty {
                db.deleteCollection(c.id)
                continue
            }
            var node: [String: Any] = ["name": c.name, "filenames": filenames]
            if !children.isEmpty { node["children"] = children }
            arr.append(node)
        }
        return arr
    }

    /// 应用远端分组（对齐 CloudSync.applyRemoteCollections / sync._apply_remote_collections）
    static func applyRemoteCollections(db: MemeDb, manifest: [String: Any]) {
        guard let arr = manifest["collections"] as? [[String: Any]] else { return }
        for node in arr {
            let name = node["name"] as? String ?? ""
            if name.isEmpty { continue }
            let cid = db.createCollection(name: name)
            if cid < 0 { continue }
            for fname in node["filenames"] as? [String] ?? [] {
                if let row = db.getByFilename(fname) {
                    db.addToCollection(row.id, cid)
                }
            }
        }
    }

    /// 应用远端顺序（对齐 CloudSync.applyRemoteOrder）
    static func applyRemoteOrder(db: MemeDb, manifest: [String: Any]) {
        var orderedIds: [Int64] = []
        for m in manifest["memes"] as? [[String: Any]] ?? [] {
            let fname = m["filename"] as? String ?? ""
            if !isSafeRemoteFname(fname) { continue }
            if let row = db.getByFilename(fname) {
                orderedIds.append(row.id)
            }
        }
        if !orderedIds.isEmpty {
            db.reorderMemes(orderedIds)
        }
    }
}
