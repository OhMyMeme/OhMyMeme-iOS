import Foundation
import CryptoKit
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// 云端同步：FTP / S3（兼容 R2 / MinIO）/ WebDAV。
/// 与桌面端 src/sync.py + manifest.py、安卓端 CloudSync.kt 对齐：
/// 远端 memes/ 目录 + meme-index.json 清单，流式哈希比对跳过已同步文件。
/// 本实现为顺序单连接编排（单线程），不复制桌面端的多 worker 并发。
enum CloudSync {

    struct SyncError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        init(_ message: String) { self.message = message }
    }

    struct SyncResult {
        var uploaded = 0
        var downloaded = 0
        var skipped = 0
        var errors = 0
        var deleted = 0
        var removedLocal = 0
        var failed: [String] = []
    }

    /// 顺序同步进度。onProgress 在工作线程回调，UI 需自行切主线程。
    final class SyncProgress {
        var filesTotal = 0
        var bytesTotal = 0
        var filesDone = 0
        var bytesDone = 0
        var currentFile = ""
        var onProgress: ((SyncProgress) -> Void)?

        func report(bytes: Int, file: String) {
            filesDone += 1
            bytesDone += bytes
            currentFile = file
            onProgress?(self)
        }
    }

    // MARK: - 公开 API

    /// 测试当前配置的存储后端连接，返回 "ok" 或错误信息
    static func syncTest() -> String {
        do {
            let cfg = configDict()
            let bk = try createBackend(cfg)
            defer { bk.close() }
            try bk.connect()
            try bk.testConnection()
            return "ok"
        } catch {
            return (error as? SyncError)?.message ?? "\(error)"
        }
    }

    /// 对比本地与远端清单，返回状态文本
    static func checkSyncStatus(db: MemeDb) -> String {
        do {
            let cfg = configDict()
            let bk = try createBackend(cfg)
            defer { bk.close() }
            try bk.connect()
            guard let data = try downloadIndex(bk, cfg: cfg) else { return "无法获取远端清单" }
            let remoteSet = Set(parseMemes(data).keys)
            let localSet = Set(entriesFromDb(db).keys)
            let extra = localSet.subtracting(remoteSet)
            let missing = remoteSet.subtracting(localSet)
            if extra.isEmpty && missing.isEmpty {
                return "已同步（本地 \(localSet.count)，远端 \(remoteSet.count)）"
            }
            var sb = "本地 \(localSet.count)，远端 \(remoteSet.count)"
            if !extra.isEmpty {
                sb += "\n仅本地: \(extra.sorted().joined(separator: ", ").prefix(120))"
            }
            if !missing.isEmpty {
                sb += "\n仅远端: \(missing.sorted().joined(separator: ", ").prefix(120))"
            }
            return sb
        } catch {
            return (error as? SyncError)?.message ?? "\(error)"
        }
    }

    /// 本地 -> 远端：上传缺失/变更的表情包和清单（顺序执行）
    static func push(db: MemeDb, progress: SyncProgress? = nil) throws -> SyncResult {
        let cfg = configDict()
        let root = remoteRoot(cfg)
        let cacheDir = StoragePaths.cacheDir
        let deleteRemote = cfgBool(cfg, "sync_delete_remote")
        let local = entriesFromDb(db)
        if local.isEmpty { throw SyncError("local manifest is empty, nothing to push") }

        let bk = try createBackend(cfg)
        defer { bk.close() }
        try bk.connect()
        try bk.ensureRemoteDir(root)
        let remoteData = try downloadIndex(bk, cfg: cfg)
        let remote = remoteData.map(parseMemes) ?? [:]

        var bytesTotal = 0
        for fname in local.keys {
            let f = cacheDir.appendingPathComponent(fname)
            bytesTotal += ((try? FileManager.default.attributesOfItem(atPath: f.path))?[.size] as? Int) ?? 0
        }
        progress?.filesTotal = local.count
        progress?.bytesTotal = bytesTotal

        var uploaded = 0
        var skipped = 0
        var errors = 0
        var failed: [String] = []
        let memeDir = trimSlashes(root) + "/" + Manifest.remoteMemeDir

        for (fname, entry) in local {
            let localFile = cacheDir.appendingPathComponent(fname)
            let remoteEntry = remote[fname]
            if remoteEntry?["sha256"] as? String == entry["sha256"] as? String,
               bk.fileExists(remoteMemePath(root, fname)) {
                skipped += 1
                progress?.report(bytes: 0, file: fname)
                continue
            }
            guard FileManager.default.fileExists(atPath: localFile.path) else {
                errors += 1
                failed.append(fname)
                progress?.report(bytes: 0, file: fname)
                continue
            }
            try? bk.ensureRemoteDir(memeDir)
            if bk.uploadFile(from: localFile, to: remoteMemePath(root, fname)) {
                uploaded += 1
                let size = ((try? FileManager.default.attributesOfItem(atPath: localFile.path))?[.size] as? Int) ?? 0
                progress?.report(bytes: size, file: fname)
            } else {
                errors += 1
                failed.append(fname)
                progress?.report(bytes: 0, file: fname)
            }
        }
        if errors > 0 { throw SyncError("\(errors) 个文件上传失败，未更新远端清单") }

        var deleted = 0
        var deletedFnames = Set<String>()
        if deleteRemote {
            for fname in remote.keys where local[fname] == nil {
                if bk.deleteFile(remoteMemePath(root, fname)) {
                    deletedFnames.insert(fname)
                    deleted += 1
                }
            }
        }

        // 远端仍保留、但本地清单没有的项合并进待上传清单，避免孤儿
        var data = Manifest.buildManifest(db: db)
        let localFnames = Set(local.keys)
        let kept = remote.values.filter { entry in
            guard let fname = entry["filename"] as? String else { return false }
            return !localFnames.contains(fname) && !deletedFnames.contains(fname)
        }
        if !kept.isEmpty {
            var memes = data["memes"] as? [[String: Any]] ?? []
            memes.append(contentsOf: kept)
            data["memes"] = memes
        }
        let indexFile = try writeTempIndex(data)
        defer { try? FileManager.default.removeItem(at: indexFile) }
        guard bk.uploadFile(from: indexFile, to: remoteIndexPath(root)) else {
            throw SyncError("远端清单上传失败")
        }
        return SyncResult(uploaded: uploaded, skipped: skipped, errors: 0, deleted: deleted, failed: failed)
    }

    /// 远端 -> 本地：下载缺失/变更的表情包和清单（顺序执行）
    static func pull(db: MemeDb, progress: SyncProgress? = nil) throws -> SyncResult {
        let cfg = configDict()
        let root = remoteRoot(cfg)
        let cacheDir = StoragePaths.cacheDir
        let removeLocal = cfgBool(cfg, "sync_remove_local")

        let bk = try createBackend(cfg)
        defer { bk.close() }
        try bk.connect()
        guard let remoteData = try downloadIndex(bk, cfg: cfg) else {
            throw SyncError("no remote manifest available")
        }
        let remote = parseMemes(remoteData)
        let local = entriesFromDb(db)

        var bytesTotal = 0
        for (fname, rentry) in remote {
            let localFile = cacheDir.appendingPathComponent(fname)
            let localHash = (local[fname]?["sha256"] as? String) ?? ""
            let remoteHash = (rentry["sha256"] as? String) ?? ""
            if localHash == remoteHash && FileManager.default.fileExists(atPath: localFile.path) { continue }
            bytesTotal += rentry["file_size"] as? Int ?? 0
        }
        progress?.filesTotal = remote.count
        progress?.bytesTotal = bytesTotal

        var downloaded = 0
        var skipped = 0
        var errors = 0
        var failed: [String] = []

        for (fname, rentry) in remote {
            if !Manifest.isSafeRemoteFname(fname) {
                errors += 1
                failed.append(fname)
                progress?.report(bytes: 0, file: fname)
                continue
            }
            let localFile = cacheDir.appendingPathComponent(fname)
            let localHash = (local[fname]?["sha256"] as? String) ?? ""
            let remoteHash = (rentry["sha256"] as? String) ?? ""
            if localHash == remoteHash && FileManager.default.fileExists(atPath: localFile.path) {
                skipped += 1
                progress?.report(bytes: 0, file: fname)
                continue
            }
            let tmp = cacheDir.appendingPathComponent(".pull-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: tmp) }
            if bk.downloadFile(remoteMemePath(root, fname), to: tmp) {
                guard let data = try? Data(contentsOf: tmp), !data.isEmpty else {
                    errors += 1
                    failed.append(fname)
                    progress?.report(bytes: 0, file: fname)
                    continue
                }
                guard MemeImporter.isValidImage(data) else {
                    errors += 1
                    failed.append(fname)
                    progress?.report(bytes: 0, file: fname)
                    continue
                }
                try? FileManager.default.removeItem(at: localFile)
                try? FileManager.default.moveItem(at: tmp, to: localFile)
                if db.getByFilename(fname) == nil {
                    let dims = ImageInfo.bounds(data)
                    let oname = (rentry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? FileUtils.stem(fromName: fname)
                    let ext = (fname as NSString).pathExtension.lowercased()
                    let mime = ext.isEmpty ? "image/png" : "image/\(ext)"
                    _ = db.addMeme(
                        filename: fname,
                        fileHash: rentry["sha256"] as? String ?? "",
                        width: dims.w,
                        height: dims.h,
                        fileSize: Int64(data.count),
                        mimeType: mime,
                        originalName: oname
                    )
                }
                downloaded += 1
                progress?.report(bytes: rentry["file_size"] as? Int ?? data.count, file: fname)
            } else {
                errors += 1
                failed.append(fname)
                progress?.report(bytes: 0, file: fname)
            }
        }

        var removedLocal = 0
        if removeLocal {
            for fname in local.keys where remote[fname] == nil {
                if let row = db.getByFilename(fname) {
                    try? FileManager.default.removeItem(at: Thumbnailer.thumbnailURL(for: row.id))
                    db.deleteMeme(row.id)
                }
                let f = cacheDir.appendingPathComponent(fname)
                if FileManager.default.fileExists(atPath: f.path) {
                    try? FileManager.default.removeItem(at: f)
                    removedLocal += 1
                }
            }
        }

        Manifest.applyRemoteCollections(db: db, manifest: remoteData)
        Manifest.applyRemoteOrder(db: db, manifest: remoteData)
        if errors > 0 { throw SyncError("\(errors) 个文件下载失败，本地清单仅包含成功项") }
        return SyncResult(downloaded: downloaded, skipped: skipped, errors: 0, removedLocal: removedLocal, failed: failed)
    }

    /// 删除远端所有表情包和清单
    static func deleteAllRemote() -> (Bool, String) {
        do {
            let cfg = configDict()
            let root = remoteRoot(cfg)
            let bk = try createBackend(cfg)
            defer { bk.close() }
            try bk.connect()
            let data = try downloadIndex(bk, cfg: cfg)
            let remote = data.map(parseMemes) ?? [:]
            var count = 0
            for fname in remote.keys {
                if bk.deleteFile(remoteMemePath(root, fname)) { count += 1 }
            }
            _ = bk.deleteFile(remoteIndexPath(root))
            return (true, "已删除 \(count) 个远端文件")
        } catch {
            return (false, (error as? SyncError)?.message ?? "\(error)")
        }
    }

    /// 识别远端孤儿文件；delete=true 时物理删除
    static func cleanupRemoteOrphans(delete: Bool = false) -> (Bool, String) {
        do {
            let cfg = configDict()
            let root = remoteRoot(cfg)
            let bk = try createBackend(cfg)
            defer { bk.close() }
            try bk.connect()
            let memeDir = trimSlashes(root) + "/" + Manifest.remoteMemeDir
            let remoteFiles = bk.listFiles(memeDir)
            let data = try? downloadIndex(bk, cfg: cfg)
            let remoteMemes = data.map { Set(parseMemes($0).keys) } ?? Set()
            let orphans = remoteFiles.filter { !remoteMemes.contains($0) }
            var removed = 0
            if delete {
                for fname in orphans {
                    if bk.deleteFile(remoteMemePath(root, fname)) { removed += 1 }
                }
            }
            let msg = delete ? "已删除 \(removed) 个孤儿文件（共 \(orphans.count)）" : "发现孤儿文件 \(orphans.count) 个"
            return (true, msg)
        } catch {
            return (false, (error as? SyncError)?.message ?? "\(error)")
        }
    }

    /// 删除本地所有表情包（文件 + 缩略图 + 数据库）
    static func deleteAllLocal(db: MemeDb) -> Int {
        let memes = db.getAll(offset: 0, limit: Int.max)
        let cache = StoragePaths.cacheDir
        var count = 0
        for m in memes {
            let f = cache.appendingPathComponent(m.filename)
            if FileManager.default.fileExists(atPath: f.path) {
                try? FileManager.default.removeItem(at: f)
                count += 1
            }
            try? FileManager.default.removeItem(at: Thumbnailer.thumbnailURL(for: m.id))
        }
        db.deleteAll()
        return count
    }

    // MARK: - 路径与清单辅助

    private static func configDict() -> [String: Any] {
        var d: [String: Any] = [:]
        for k in ConfigStore.allKeys {
            if let v = ConfigStore.shared.value(k) { d[k] = v }
        }
        return d
    }

    private static func remoteRoot(_ cfg: [String: Any]) -> String {
        switch cfgStr(cfg, "sync_type") {
        case "ftp": return cfgStr(cfg, "ftp_path")
        case "webdav": return cfgStr(cfg, "webdav_path")
        default: return ""
        }
    }

    private static func remoteIndexPath(_ root: String) -> String {
        trimSlashes(root) + "/" + Manifest.indexFilename
    }

    private static func remoteMemePath(_ root: String, _ filename: String) -> String {
        trimSlashes(root) + "/" + Manifest.remoteMemeDir + "/" + filename
    }

    private static func entriesFromDb(_ db: MemeDb) -> [String: [String: Any]] {
        var map: [String: [String: Any]] = [:]
        for m in db.getAll(offset: 0, limit: Int.max) {
            map[m.filename] = [
                "filename": m.filename,
                "name": m.originalName.isEmpty ? FileUtils.stem(fromName: m.filename) : m.originalName,
                "sha256": m.fileHash,
                "file_size": m.fileSize
            ]
        }
        return map
    }

    private static func parseMemes(_ data: [String: Any]) -> [String: [String: Any]] {
        var map: [String: [String: Any]] = [:]
        for m in data["memes"] as? [[String: Any]] ?? [] {
            if let fname = m["filename"] as? String, !fname.isEmpty {
                map[fname] = m
            }
        }
        return map
    }

    private static func downloadIndex(_ bk: Backend, cfg: [String: Any]) throws -> [String: Any]? {
        let root = remoteRoot(cfg)
        let remotePath = remoteIndexPath(root)
        guard bk.fileExists(remotePath) else { return nil }
        let tmp = StoragePaths.dataDir.appendingPathComponent(".remote-index.json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard bk.downloadFile(remotePath, to: tmp) else { throw SyncError("远端清单下载失败") }
        guard let data = try? Data(contentsOf: tmp),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw SyncError("远端清单解析失败") }
        return obj
    }

    private static func writeTempIndex(_ data: [String: Any]) throws -> URL {
        let tmp = StoragePaths.dataDir.appendingPathComponent(".local-index.json")
        guard JSONSerialization.isValidJSONObject(data),
              let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        else { throw SyncError("清单序列化失败") }
        try json.write(to: tmp)
        return tmp
    }

    private static func createBackend(_ cfg: [String: Any]) throws -> Backend {
        switch cfgStr(cfg, "sync_type") {
        case "ftp": return FtpBackend(cfg: cfg)
        case "s3": return S3Backend(cfg: cfg, isR2: false)
        case "r2": return S3Backend(cfg: cfg, isR2: true)
        case "webdav": return WebDavBackend(cfg: cfg)
        default: throw SyncError("No sync type configured")
        }
    }

    // MARK: - 后端抽象

    private protocol Backend: AnyObject {
        func connect() throws
        func testConnection() throws
        func ensureRemoteDir(_ path: String) throws
        func uploadFile(from local: URL, to remotePath: String) -> Bool
        func downloadFile(_ remotePath: String, to dest: URL) -> Bool
        func fileExists(_ path: String) -> Bool
        func deleteFile(_ path: String) -> Bool
        func listFiles(_ path: String) -> [String]
        func close()
    }

    // MARK: - FTP 后端（POSIX socket 直写，被动模式）

    private final class FtpBackend: Backend {
        private let cfg: [String: Any]
        private var fd: Int32 = -1
        private var lineBuf = Data()

        init(cfg: [String: Any]) { self.cfg = cfg }

        func connect() throws {
            let host = cfgStr(cfg, "ftp_host")
            if host.isEmpty { throw SyncError("FTP host not configured") }
            let port = cfgInt(cfg, "ftp_port") == 0 ? 21 : cfgInt(cfg, "ftp_port")
            let user = cfgStr(cfg, "ftp_user")
            let password = cfgStr(cfg, "ftp_password")
            do {
                fd = try FtpBackend.socket(host: host, port: port)
                setControlTimeout(60_000)
                _ = try readReply() // 220 greeting
                if user.isEmpty {
                    _ = try cmd("USER anonymous")
                } else {
                    _ = try cmd("USER \(user)")
                }
                _ = try cmd("PASS \(password)")
            } catch {
                close()
                if let e = error as? SyncError { throw e }
                throw SyncError("FTP connect failed: \(error)")
            }
        }

        func testConnection() throws {}

        func ensureRemoteDir(_ path: String) throws {
            let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            var sofar = ""
            for p in parts {
                sofar += "/" + p
                do {
                    _ = try cmd("CWD \(sofar)")
                } catch {
                    _ = try? cmd("MKD \(sofar)")
                    _ = try cmd("CWD \(sofar)")
                }
            }
        }

        func uploadFile(from local: URL, to remotePath: String) -> Bool {
            var dataSock: Int32 = -1
            do {
                dataSock = try openDataSocket()
                _ = try cmd("STOR \(remotePath)") // 150
                guard let handle = try? FileHandle(forReadingFrom: local) else {
                    if dataSock >= 0 { _ = Darwin.close(dataSock) }
                    dataSock = -1
                    return false
                }
                defer { try? handle.close() }
                while true {
                    let chunk = handle.readData(ofLength: 65536)
                    if chunk.isEmpty { break }
                    try sendAll(chunk, on: dataSock)
                }
                _ = Darwin.close(dataSock)
                dataSock = -1
                let code = try readReply() // 226
                return code >= 200 && code < 300
            } catch {
                if dataSock >= 0 { _ = Darwin.close(dataSock) }
                return false
            }
        }

        func downloadFile(_ remotePath: String, to dest: URL) -> Bool {
            var dataSock: Int32 = -1
            do {
                dataSock = try openDataSocket()
                _ = try cmd("RETR \(remotePath)") // 150
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
                    if dataSock >= 0 { _ = Darwin.close(dataSock) }
                    dataSock = -1
                    return false
                }
                let out = try FileHandle(forWritingTo: dest)
                defer { try? out.close() }
                var tmp = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = tmp.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Int in
                        guard let base = ptr.baseAddress else { return -1 }
                        return recv(dataSock, base, tmp.count, 0)
                    }
                    if n == 0 { break }
                    if n < 0 { throw SyncError("FTP 数据读取失败") }
                    try out.write(contentsOf: tmp[0..<n])
                }
                _ = Darwin.close(dataSock)
                dataSock = -1
                _ = try readReply() // 226
                return true
            } catch {
                if dataSock >= 0 { _ = Darwin.close(dataSock) }
                try? FileManager.default.removeItem(at: dest)
                return false
            }
        }

        func fileExists(_ path: String) -> Bool {
            (try? cmd("SIZE \(path)")) != nil
        }

        func deleteFile(_ path: String) -> Bool {
            do {
                _ = try cmd("DELE \(path)")
                return true
            } catch let e as SyncError {
                return e.message.contains("550") // 550 = 文件不存在，视为删除成功
            } catch {
                return false
            }
        }

        func listFiles(_ path: String) -> [String] {
            var dataSock: Int32 = -1
            var names: [String] = []
            do {
                dataSock = try openDataSocket()
                _ = try cmd("NLST \(path)")
                var all = Data()
                var tmp = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = tmp.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Int in
                        guard let base = ptr.baseAddress else { return -1 }
                        return recv(dataSock, base, tmp.count, 0)
                    }
                    if n == 0 { break }
                    if n < 0 { throw SyncError("FTP NLST 读取失败") }
                    all.append(contentsOf: tmp[0..<n])
                }
                _ = Darwin.close(dataSock)
                dataSock = -1
                _ = try readReply()
                let text = String(data: all, encoding: .utf8) ?? ""
                for line in text.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !trimmed.hasSuffix("/") {
                        names.append((trimmed as NSString).lastPathComponent)
                    }
                }
                return names
            } catch {
                if dataSock >= 0 { _ = Darwin.close(dataSock) }
                return []
            }
        }

        func close() {
            if fd >= 0 {
                _ = try? cmd("QUIT")
                _ = Darwin.close(fd)
                fd = -1
            }
        }

        // MARK: FTP 内部

        private func setControlTimeout(_ ms: Int) {
            guard fd >= 0 else { return }
            var tv = timeval(tv_sec: ms / 1000, tv_usec: Int32((ms % 1000) * 1000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }

        private func openDataSocket() throws -> Int32 {
            let addr = try pasv()
            return try FtpBackend.socket(addr: addr, timeoutMs: 30_000)
        }

        private func pasv() throws -> sockaddr_in {
            let reply = try cmdText("PASV")
            guard let openParen = reply.firstIndex(of: "("),
                  let closeParen = reply.firstIndex(of: ")"),
                  closeParen > openParen
            else { throw SyncError("FTP 服务器未返回 PASV 地址") }
            let inner = reply[reply.index(after: openParen)..<closeParen]
            let parts = inner.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 6,
                  let p1 = Int(parts[4]),
                  let p2 = Int(parts[5])
            else { throw SyncError("FTP PASV 响应格式错误") }
            let host = "\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3])"
            let port = p1 * 256 + p2
            guard let h = inet_addr(host), h != INADDR_NONE else {
                throw SyncError("FTP PASV 地址无效: \(host)")
            }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = h
            return addr
        }

        @discardableResult
        private func cmd(_ line: String) throws -> Int {
            try sendAll(Data((line + "\r\n").utf8), on: fd)
            return try readReply()
        }

        /// 发送命令并返回最后一行响应文本（供解析 PASV 等含数据的响应）
        @discardableResult
        private func cmdText(_ line: String) throws -> String {
            try sendAll(Data((line + "\r\n").utf8), on: fd)
            return try readReplyText()
        }

        @discardableResult
        private func readReply() throws -> Int {
            let text = try readReplyText()
            return Int(text.prefix(3)) ?? -1
        }

        @discardableResult
        private func readReplyText() throws -> String {
            let first = try readLine()
            guard first.count >= 3, let code = Int(first.prefix(3)) else {
                throw SyncError("FTP 响应异常: \(first)")
            }
            var last = first
            if first.count > 3, Array(first)[3] == "-" {
                while true {
                    last = try readLine()
                    if last.count >= 4, last.hasPrefix("\(code) ") { break }
                }
            }
            if code >= 400 { throw SyncError("FTP server error: \(last)") }
            return last
        }

        private func readLine() throws -> String {
            while true {
                if let nl = lineBuf.firstIndex(of: 0x0A) {
                    var line = String(data: lineBuf[lineBuf.startIndex..<nl], encoding: .utf8) ?? ""
                    lineBuf.removeSubrange(lineBuf.startIndex...nl)
                    if line.hasSuffix("\r") { line.removeLast() }
                    return line
                }
                var tmp = [UInt8](repeating: 0, count: 4096)
                let n = tmp.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return recv(fd, base, tmp.count, 0)
                }
                if n == 0 { throw SyncError("FTP 连接已关闭") }
                if n < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw SyncError("FTP 读取超时") }
                    throw SyncError("FTP 读取失败: \(String(cString: strerror(errno)))")
                }
                lineBuf.append(contentsOf: tmp[0..<n])
            }
        }

        private func sendAll(_ data: Data, on target: Int32) throws {
            guard target >= 0 else { throw SyncError("FTP 未连接") }
            try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                guard let base = ptr.baseAddress else { return }
                var total = 0
                while total < data.count {
                    let w = send(target, base.advanced(by: total), data.count - total, 0)
                    if w <= 0 {
                        throw SyncError("FTP 发送失败: \(String(cString: strerror(errno)))")
                    }
                    total += w
                }
            }
        }

        private static func socket(host: String, port: Int) throws -> Int32 {
            let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { throw SyncError("创建 socket 失败") }
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>? = nil
            let rc = getaddrinfo(host, String(port), &hints, &res)
            guard rc == 0, let addr = res?.pointee else {
                if res != nil { freeaddrinfo(res) }
                _ = Darwin.close(sock)
                throw SyncError("FTP 主机无法解析: \(host)")
            }
            defer { freeaddrinfo(res) }
            let c = Darwin.connect(sock, addr.ai_addr, socklen_t(addr.ai_addrlen))
            if c != 0 {
                _ = Darwin.close(sock)
                throw SyncError("FTP 连接失败: \(String(cString: strerror(errno)))")
            }
            var tv = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            return sock
        }

        private static func socket(addr: sockaddr_in, timeoutMs: Int) throws -> Int32 {
            let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { throw SyncError("创建 socket 失败") }
            var addrCopy = addr
            var flags = fcntl(sock, F_GETFL, 0)
            _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
            let c = withUnsafePointer(to: &addrCopy) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                    Darwin.connect(sock, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if c != 0 {
                guard errno == EINPROGRESS else {
                    _ = Darwin.close(sock)
                    throw SyncError("FTP 数据连接失败")
                }
                var wfd = fd_set()
                withUnsafeMutableBytes(of: &wfd) { raw in
                    raw.initializeMemory(as: UInt8.self, repeating: 0)
                }
                withUnsafeMutableBytes(of: &wfd) { raw in
                    let base = raw.bindMemory(to: Int32.self).baseAddress!
                    let idx = Int(sock) / 32
                    let bit = Int32(1) << Int32(sock % 32)
                    base[idx] |= bit
                }
                var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
                let s = select(sock + 1, nil, &wfd, nil, &tv)
                if s <= 0 {
                    _ = Darwin.close(sock)
                    throw SyncError("FTP 数据连接超时")
                }
                var soErr: Int32 = 0
                var soLen = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &soErr, &soLen)
                if soErr != 0 {
                    _ = Darwin.close(sock)
                    throw SyncError("FTP 数据连接失败")
                }
            }
            _ = fcntl(sock, F_SETFL, flags)
            var rtv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &rtv, socklen_t(MemoryLayout<timeval>.size))
            return sock
        }
    }

    // MARK: - SigV4 签名（供 S3Backend 与测试共用）

    /// 计算 AWS SigV4 签名。固定格式：UNSIGNED-PAYLOAD，
    /// signed headers = host;x-amz-content-sha256;x-amz-date（与桌面端/安卓端一致）。
    /// 参考向量（botocore 独立生成）：
    ///   PUT  /meme-bucket/memes/abc1234567890def.png  → 9165877cc16916cc65b869bb6e52ac4586d82b61a57922fede69fc90d58369d2
    ///   GET  /meme-bucket?list-type=2&prefix=memes%2F → 8a191c9d67a432b838c3a06429d141d17f8cb655f61c1f34cdd215d6875b48b5
    static func sigV4Signature(
        method: String, path: String, query: String, host: String,
        region: String, amzDate: String, dateStamp: String,
        accessKey: String, secretKey: String
    ) -> String {
        let payloadHash = "UNSIGNED-PAYLOAD"
        let canonicalHeaders = "host:\(host)\n" +
            "x-amz-content-sha256:\(payloadHash)\n" +
            "x-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = "\(method)\n\(path)\n\(query)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(sha256Hex(Data(canonicalRequest.utf8)))"
        let dateKey = hmac(Data(("AWS4" + secretKey).utf8), dateStamp)
        let regionKey = hmac(dateKey, region)
        let serviceKey = hmac(regionKey, "s3")
        let signingKey = hmac(serviceKey, "aws4_request")
        return hmac(signingKey, stringToSign).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ data: String) -> Data {
        let symKey = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: symKey))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - S3 后端（SigV4，兼容 R2 / MinIO）

    private final class S3Backend: Backend {
        private let cfg: [String: Any]
        private let isR2: Bool
        private var endpoint = ""
        private var region = ""
        private var accessKey = ""
        private var secretKey = ""
        private var bucket = ""
        private var prefix = ""

        init(cfg: [String: Any], isR2: Bool) {
            self.cfg = cfg
            self.isR2 = isR2
        }

        private static let dateStampFmt: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd"
            return f
        }()
        private static let amzDateFmt: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return f
        }()

        func connect() throws {
            if isR2 {
                let accountId = cfgStr(cfg, "r2_account_id")
                bucket = cfgStr(cfg, "r2_bucket")
                accessKey = cfgStr(cfg, "r2_access_key_id")
                secretKey = cfgStr(cfg, "r2_secret_access_key")
                if accountId.isEmpty || bucket.isEmpty { throw SyncError("R2 account ID and bucket not configured") }
                if accessKey.isEmpty || secretKey.isEmpty { throw SyncError("R2 credentials not configured") }
                endpoint = "https://\(accountId).r2.cloudflarestorage.com"
                prefix = cfgStr(cfg, "r2_path").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                endpoint = cfgStr(cfg, "s3_endpoint")
                bucket = cfgStr(cfg, "s3_bucket")
                region = cfgStr(cfg, "s3_region")
                accessKey = cfgStr(cfg, "s3_access_key")
                secretKey = cfgStr(cfg, "s3_secret_key")
                if endpoint.isEmpty || bucket.isEmpty { throw SyncError("S3 endpoint or bucket not configured") }
                prefix = cfgStr(cfg, "s3_path").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            if region.isEmpty { region = "us-east-1" }
        }

        func testConnection() throws {}

        func ensureRemoteDir(_ path: String) throws {}

        func uploadFile(from local: URL, to remotePath: String) -> Bool {
            do {
                let data = try Data(contentsOf: local)
                var req = signedRequest(method: "PUT", path: canonPath(key(remotePath)))
                req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                req.httpBody = data
                let (code, _) = try perform(req)
                return (200...299).contains(code)
            } catch {
                return false
            }
        }

        func downloadFile(_ remotePath: String, to dest: URL) -> Bool {
            do {
                let req = signedRequest(method: "GET", path: canonPath(key(remotePath)))
                let (code, data) = try perform(req)
                guard (200...299).contains(code) else { return false }
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest)
                return true
            } catch {
                return false
            }
        }

        func fileExists(_ path: String) -> Bool {
            do {
                let req = signedRequest(method: "HEAD", path: canonPath(key(path)))
                let (code, _) = try perform(req)
                return (200...299).contains(code)
            } catch {
                return false
            }
        }

        func deleteFile(_ path: String) -> Bool {
            do {
                let req = signedRequest(method: "DELETE", path: canonPath(key(path)))
                let (code, _) = try perform(req)
                return (200...299).contains(code)
            } catch {
                return false
            }
        }

        func listFiles(_ path: String) -> [String] {
            do {
                let prefixKey = key(path)
                var p = prefixKey
                if !p.isEmpty && !p.hasSuffix("/") { p += "/" }
                let query = "list-type=2&prefix=\(encodeSegment(p))"
                let req = signedRequest(method: "GET", path: "/\(bucket)", query: query)
                let (code, body) = try perform(req)
                guard (200...299).contains(code) else { return [] }
                var files: [String] = []
                let text = String(data: body, encoding: .utf8) ?? ""
                let ns = text as NSString
                if let re = try? NSRegularExpression(pattern: "<Key>(.*?)</Key>") {
                    re.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                        guard let m else { return }
                        let k = ns.substring(with: m.range(at: 1))
                        if !k.hasSuffix("/") && k.hasPrefix(p) {
                            let name = String(k.dropFirst(p.count))
                            if !name.isEmpty { files.append(name) }
                        }
                    }
                }
                return files
            } catch {
                return []
            }
        }

        func close() {}

        // MARK: S3 内部

        private func key(_ remotePath: String) -> String {
            let rel = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return prefix.isEmpty ? rel : "\(prefix)/\(rel)"
        }

        private func canonPath(_ key: String) -> String {
            let encoded = key.split(separator: "/").map { encodeSegment(String($0)) }.joined(separator: "/")
            return "/\(bucket)/\(encoded)"
        }

        private func encodeSegment(_ seg: String) -> String {
            var out = ""
            for b in seg.utf8 {
                let c = Int(b)
                let isUnreserved = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
                    (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F || c == 0x2E || c == 0x7E
                if isUnreserved {
                    out.append(Character(UnicodeScalar(c)!))
                } else {
                    out += String(format: "%%%02X", c)
                }
            }
            return out
        }

        private var endpointHost: String {
            guard let u = URL(string: endpoint) else { return "" }
            let h = u.host ?? ""
            if let port = u.port { return "\(h):\(port)" }
            return h
        }

        private func signedRequest(method: String, path: String, query: String = "") -> URLRequest {
            let host = endpointHost
            let now = Date()
            let amzDate = Self.amzDateFmt.string(from: now)
            let dateStamp = Self.dateStampFmt.string(from: now)
            let signature = CloudSync.sigV4Signature(
                method: method, path: path, query: query, host: host,
                region: region, amzDate: amzDate, dateStamp: dateStamp,
                accessKey: accessKey, secretKey: secretKey
            )
            let scope = "\(dateStamp)/\(region)/s3/aws4_request"
            let payloadHash = "UNSIGNED-PAYLOAD"
            let signedHeaders = "host;x-amz-content-sha256;x-amz-date"

            var urlString = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
            if !query.isEmpty { urlString += "?\(query)" }
            let url = URL(string: urlString) ?? URL(string: endpoint)!
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue(host, forHTTPHeaderField: "Host")
            req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
            req.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
            req.setValue(
                "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                forHTTPHeaderField: "Authorization"
            )
            req.timeoutInterval = 60
            return req
        }

        private func perform(_ request: URLRequest) throws -> (Int, Data) {
            let sem = DispatchSemaphore(value: 0)
            var code = 0
            var data = Data()
            var requestError: Error?
            let task = URLSession.shared.dataTask(with: request) { d, resp, err in
                requestError = err
                code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                data = d ?? Data()
                sem.signal()
            }
            task.resume()
            if sem.wait(timeout: .now() + 60) == .timedOut {
                task.cancel()
                throw SyncError("请求超时")
            }
            if let requestError {
                throw SyncError("请求失败: \(requestError.localizedDescription)")
            }
            return (code, data)
        }
    }

    // MARK: - WebDAV 后端（URLSession 直写，支持任意 HTTP 方法）

    private final class WebDavBackend: Backend {
        private let cfg: [String: Any]
        private var baseUrl = ""
        private var authHeader = ""
        private var timeout = 30

        init(cfg: [String: Any]) { self.cfg = cfg }

        func connect() throws {
            let url = cfgStr(cfg, "webdav_url")
            if url.isEmpty { throw SyncError("WebDAV url not configured") }
            guard let u = URL(string: url),
                  let scheme = u.scheme,
                  ["http", "https"].contains(scheme),
                  let host = u.host,
                  !host.isEmpty
            else { throw SyncError("WebDAV URL 必须以 http:// 或 https:// 开头") }
            let portStr = u.port.map { ":\($0)" } ?? ""
            let encPath = u.path.split(separator: "/").map { encodeSegment(String($0)) }.joined(separator: "/")
            var base = "\(scheme)://\(host)\(portStr)"
            if !encPath.isEmpty { base += "/" + encPath }
            baseUrl = trimSlashes(base)
            let user = cfgStr(cfg, "webdav_user")
            let password = cfgStr(cfg, "webdav_password")
            if !user.isEmpty {
                let token = Data("\(user):\(password)".utf8).base64EncodedString()
                authHeader = "Basic \(token)"
            }
            timeout = max(5, cfgInt(cfg, "webdav_timeout"))
        }

        func testConnection() throws {
            let url = davUrl(cfgStr(cfg, "webdav_path"))
            do {
                let (code, _) = try perform("PROPFIND", url: url, headers: ["Depth": "0"])
                if !(200...299).contains(code) {
                    throw SyncError("WebDAV PROPFIND returned HTTP \(code)")
                }
            } catch let e as SyncError {
                throw e
            } catch {
                throw SyncError("WebDAV 网络不可达: \(error)")
            }
        }

        func ensureRemoteDir(_ path: String) throws {
            var rel = ""
            for p in path.split(separator: "/") {
                rel += "/" + String(p)
                do {
                    let (code, _) = try perform("MKCOL", url: davUrl(rel))
                    if (200...399).contains(code) { continue }
                    if fileExists(rel) { continue }
                    throw SyncError("MKCOL \(rel) 失败: HTTP \(code)")
                } catch let e as SyncError {
                    throw e
                } catch {
                    if fileExists(rel) { continue }
                    throw SyncError("MKCOL \(rel) 失败: \(error)")
                }
            }
        }

        func uploadFile(from local: URL, to remotePath: String) -> Bool {
            do {
                let data = try Data(contentsOf: local)
                let (code, _) = try perform(
                    "PUT",
                    url: davUrl(remotePath),
                    data: data,
                    headers: ["Content-Type": "application/octet-stream"]
                )
                return (200...299).contains(code)
            } catch {
                return false
            }
        }

        func downloadFile(_ remotePath: String, to dest: URL) -> Bool {
            do {
                let (code, data) = try perform("GET", url: davUrl(remotePath))
                guard (200...299).contains(code) else { return false }
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest)
                return true
            } catch {
                return false
            }
        }

        func fileExists(_ path: String) -> Bool {
            do {
                let (code, _) = try perform("PROPFIND", url: davUrl(path), headers: ["Depth": "0"])
                if (200...299).contains(code) { return true }
                if code == 404 { return false }
                if code == 405 || code == 501 {
                    let (c2, _) = try perform("HEAD", url: davUrl(path))
                    return (200...299).contains(c2)
                }
                return false
            } catch {
                return false
            }
        }

        func deleteFile(_ path: String) -> Bool {
            do {
                let (code, _) = try perform("DELETE", url: davUrl(path))
                return code == 404 || (200...299).contains(code)
            } catch {
                return false
            }
        }

        func listFiles(_ path: String) -> [String] {
            do {
                let url = davUrl(path)
                let (code, body) = try perform("PROPFIND", url: url, headers: ["Depth": "1"])
                guard (200...299).contains(code) else { return [] }
                let text = String(data: body, encoding: .utf8) ?? ""
                let ns = text as NSString
                let urlKey = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                var files: [String] = []
                if let re = try? NSRegularExpression(pattern: "<[Dd]:href>(.*?)</[Dd]:href>") {
                    re.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                        guard let m else { return }
                        var href = ns.substring(with: m.range(at: 1))
                        if href.hasSuffix("/") { return }
                        if href.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == urlKey { return }
                        if let decoded = href.removingPercentEncoding { href = decoded }
                        let name = (href as NSString).lastPathComponent
                        if !name.isEmpty { files.append(name) }
                    }
                }
                return files
            } catch {
                return []
            }
        }

        func close() {}

        // MARK: WebDAV 内部

        private func encodeSegment(_ seg: String) -> String {
            var out = ""
            for b in seg.utf8 {
                let c = Int(b)
                let isSafe = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
                    (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F || c == 0x2E || c == 0x7E || c == 0x25
                if isSafe {
                    out.append(Character(UnicodeScalar(c)!))
                } else {
                    out += String(format: "%%%02X", c)
                }
            }
            return out
        }

        private func davUrl(_ remotePath: String) -> String {
            let rel = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let enc = rel.split(separator: "/").map { encodeSegment(String($0)) }.joined(separator: "/")
            return enc.isEmpty ? baseUrl : baseUrl + "/" + enc
        }

        private func perform(
            _ method: String,
            url: String,
            data: Data? = nil,
            headers: [String: String] = [:]
        ) throws -> (Int, Data) {
            guard let u = URL(string: url) else { throw SyncError("URL 无效: \(url)") }
            var req = URLRequest(url: u)
            req.httpMethod = method
            req.setValue("OhMyMeme", forHTTPHeaderField: "User-Agent")
            if !authHeader.isEmpty { req.setValue(authHeader, forHTTPHeaderField: "Authorization") }
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            if let data {
                req.httpBody = data
            }
            req.timeoutInterval = TimeInterval(timeout)

            let sem = DispatchSemaphore(value: 0)
            var code = 0
            var body = Data()
            var requestError: Error?
            let task = URLSession.shared.dataTask(with: req) { d, resp, err in
                requestError = err
                code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                body = d ?? Data()
                sem.signal()
            }
            task.resume()
            if sem.wait(timeout: .now() + TimeInterval(timeout)) == .timedOut {
                task.cancel()
                throw SyncError("WebDAV 请求超时")
            }
            if let requestError {
                throw SyncError("WebDAV 网络不可达: \(requestError.localizedDescription)")
            }
            return (code, body)
        }
    }
}

// MARK: - 文件级辅助

private func cfgStr(_ cfg: [String: Any], _ key: String) -> String {
    cfg[key] as? String ?? ""
}

private func cfgInt(_ cfg: [String: Any], _ key: String) -> Int {
    cfg[key] as? Int ?? 0
}

private func cfgBool(_ cfg: [String: Any], _ key: String) -> Bool {
    cfg[key] as? Bool ?? false
}

private func trimSlashes(_ s: String) -> String {
    var t = s
    while t.hasSuffix("/") { t.removeLast() }
    return t
}