import Foundation
import CryptoKit
import Security
import UIKit
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// 局域网协议常量（对齐桌面端 src/lan.py 与安卓端 LanClient.kt）
enum LanProtocol {
    static let defaultPort = 17852
    static let maxFrame = 64 * 1024 * 1024
    static let maxFileSize = 64 * 1024 * 1024
    static let handshakeTimeoutMs = 10_000
    static let deviceConfirmTimeoutMs = 60_000
    static let idleTimeoutMs = 60_000
    static let ivLen = 12
    static let tagLen = 16
    static let discoverTimeoutMs = 1_500
    static let pbkdf2Salt = "ohmy-meme-lan"
    static let pbkdf2Iterations = 100_000
    static let pbkdf2KeyLen = 32
}

/// 局域网互联客户端（连接电脑端 lan.py 服务）。
/// 协议：UDP 发现 + TCP 握手（HMAC-SHA256 挑战/应答）+ AES-GCM 加密会话帧。
enum LanClient {

    struct LanPeer {
        let name: String
        let os: String
        let ver: String
        let needSecret: Bool
        let ip: String
        let port: Int
    }

    struct LanResult {
        var pulled = 0
        var pushed = 0
        var skipped = 0
        var errors = 0
        var failed: [String] = []
    }

    struct LanError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        init(_ message: String) { self.message = message }
    }

    // MARK: - UDP 发现

    /// UDP 广播发现局域网内电脑，返回应答列表（阻塞，勿在主线程调用）
    static func discover(port: Int = LanProtocol.defaultPort) -> [LanPeer] {
        var result: [LanPeer] = []
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return result }
        defer { close(sock) }

        var broadcast: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(
            tv_sec: LanProtocol.discoverTimeoutMs / 1000,
            tv_usec: Int32((LanProtocol.discoverTimeoutMs % 1000) * 1000)
        )
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let msg = try? JSONSerialization.data(withJSONObject: ["t": "discover"]) else { return result }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("255.255.255.255")
        msg.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return }
            withUnsafePointer(to: &addr) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                    _ = sendto(sock, base, msg.count, 0, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &from) { fptr in
                    fptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                        recvfrom(sock, base, 2048, 0, sap, &fromLen)
                    }
                }
            }
            if n <= 0 { break } // 超时或错误，结束发现
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(buf[0..<n]))) as? [String: Any],
                  obj["t"] as? String == "hello"
            else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            if result.contains(where: { $0.ip == ip && $0.port == port }) { continue }
            result.append(LanPeer(
                name: obj["name"] as? String ?? "未知设备",
                os: obj["os"] as? String ?? "",
                ver: obj["ver"] as? String ?? "",
                needSecret: obj["need_secret"] as? Bool ?? false,
                ip: ip,
                port: port
            ))
        }
        return result
    }

    // MARK: - 会话操作

    /// 建立加密会话并返回操作句柄（发送本机设备描述，等待电脑端确认后可用）
    static func connect(ip: String, port: Int, secret: String) throws -> LanConnection {
        let conn = LanConnection()
        try conn.connect(ip: ip, port: port, secret: secret, deviceInfo: buildDeviceInfo())
        return conn
    }

    /// 从电脑拉取表情：pull_manifest → 去重 → pull_file 逐文件导入 → applyRemoteOrder
    static func pull(db: MemeDb, conn: LanConnection) throws -> LanResult {
        var result = LanResult()
        let manifest = try conn.pullManifest()
        let remoteArr = manifest["memes"] as? [[String: Any]] ?? []
        for m in remoteArr {
            let fname = m["filename"] as? String ?? ""
            if !Manifest.isSafeRemoteFname(fname) {
                result.errors += 1
                result.failed.append(fname)
                continue
            }
            if db.getByFilename(fname) != nil {
                result.skipped += 1
                continue
            }
            do {
                let data = try conn.pullFile(filename: fname)
                if data.count > LanProtocol.maxFileSize {
                    result.errors += 1
                    result.failed.append(fname)
                    continue
                }
                let remoteHash = m["sha256"] as? String ?? ""
                if !remoteHash.isEmpty && !remoteHash.lowercased().elementsEqual(FileUtils.sha256(data)) {
                    result.errors += 1
                    result.failed.append(fname)
                    continue
                }
                if !MemeImporter.isValidImage(data) {
                    result.errors += 1
                    result.failed.append(fname)
                    continue
                }
                let oname = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? FileUtils.stem(fromName: fname)
                if MemeImporter.importData(data, originalName: oname, db: db) {
                    result.pulled += 1
                } else {
                    result.skipped += 1
                }
            } catch {
                result.errors += 1
                result.failed.append(fname)
            }
        }
        Manifest.applyRemoteOrder(db: db, manifest: manifest)
        return result
    }

    /// 推送表情到电脑：push_file 逐文件（电脑端哈希去重）→ push_manifest 同步顺序/分组
    static func push(db: MemeDb, conn: LanConnection) throws -> LanResult {
        var result = LanResult()
        let remote = try conn.pullManifest()
        var remoteNames: Set<String> = []
        for m in remote["memes"] as? [[String: Any]] ?? [] {
            if let fname = m["filename"] as? String, !fname.isEmpty {
                remoteNames.insert(fname)
            }
        }
        for m in db.getAll(offset: 0, limit: Int.max) {
            if remoteNames.contains(m.filename) {
                result.skipped += 1
                continue
            }
            guard let file = Thumbnailer.findMemeFile(m.filename),
                  let data = try? Data(contentsOf: file)
            else {
                result.errors += 1
                result.failed.append(m.filename)
                continue
            }
            do {
                try conn.pushFile(filename: m.filename, data: data)
                result.pushed += 1
            } catch {
                result.errors += 1
                result.failed.append(m.filename)
            }
        }
        do {
            try conn.pushManifest(Manifest.buildManifest(db: db))
        } catch {
            // 清单推送失败不中断统计
        }
        return result
    }

    /// 从电脑同步配置到本地。默认剔除密钥字段；includeSecrets 仅在电脑端确认
    /// allow_secret_config=true 时才传 true。覆盖本地配置，需谨慎调用。
    static func pullConfig(conn: LanConnection, includeSecrets: Bool = false) throws {
        let resp = try conn.getConfig()
        guard let cfg = resp["config"] as? [String: Any] else {
            throw LanError("配置格式错误")
        }
        for (k, v) in cfg {
            if !includeSecrets && ConfigStore.isSecretKey(k) { continue }
            ConfigStore.shared.set(k, v)
        }
        ConfigStore.shared.save()
    }

    /// 把本地配置推送到电脑。默认剔除密钥字段；includeSecrets 仅在电脑端确认
    /// allow_secret_config=true 时才传 true。覆盖电脑配置，需谨慎调用。
    static func pushConfig(conn: LanConnection, includeSecrets: Bool = false) throws {
        var copy: [String: Any] = [:]
        for k in ConfigStore.allKeys {
            if !includeSecrets && ConfigStore.isSecretKey(k) { continue }
            if let v = ConfigStore.shared.value(k) {
                copy[k] = v
            }
        }
        try conn.sendConfig(copy)
    }

    // MARK: - 加密原语

    /// HMAC-SHA256 十六进制（对齐 lan.py handshake / 安卓 hmacSha256）
    static func hmacSha256(secret: String, nonce: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// 由共享密钥派生 AES-GCM 会话密钥（PBKDF2-HMAC-SHA256，对齐桌面端 _derive_key）
    static func deriveKey(secret: String) -> Data {
        if secret.isEmpty { return Data(count: LanProtocol.pbkdf2KeyLen) }
        let password = Data(secret.utf8)
        let salt = Data(LanProtocol.pbkdf2Salt.utf8)
        let dkLen = LanProtocol.pbkdf2KeyLen
        var out = Data()
        var blockIndex: UInt32 = 1
        while out.count < dkLen {
            let u1 = pbkdf2Prf(password, salt + int32BE(blockIndex))
            var t = u1
            var u = u1
            for _ in 1..<LanProtocol.pbkdf2Iterations {
                u = pbkdf2Prf(password, u)
                t = xorBytes(t, u)
            }
            out.append(t)
            blockIndex += 1
        }
        return out.prefix(dkLen)
    }

    /// 加密帧体 = iv(12) || ct || tag（与 Java cipher.doFinal 的 ct||tag 布局一致）
    static func sealFrame(plain: Data, key: Data) throws -> Data {
        let symKey = SymmetricKey(data: key)
        var iv = Data(count: LanProtocol.ivLen)
        iv.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, LanProtocol.ivLen, base)
        }
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(plain, using: symKey, nonce: nonce)
        guard let combined = sealed.combined else {
            throw LanError("AES-GCM 加密失败")
        }
        return combined
    }

    static func unsealFrame(_ body: Data, key: Data) throws -> Data {
        guard body.count >= LanProtocol.ivLen + LanProtocol.tagLen else {
            throw LanError("帧长度非法")
        }
        let iv = body.prefix(LanProtocol.ivLen)
        let ctCount = body.count - LanProtocol.ivLen - LanProtocol.tagLen
        let ct = body.dropFirst(LanProtocol.ivLen).prefix(ctCount)
        let tag = body.suffix(LanProtocol.tagLen)
        let nonce = try AES.GCM.Nonce(data: Data(iv))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ct), tag: Data(tag))
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    private static func buildDeviceInfo() -> [String: Any] {
        let device = UIDevice.current
        return [
            "name": device.name,
            "model": device.model,
            "os": "iOS \(device.systemVersion)",
            "ver": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        ]
    }

    private static func pbkdf2Prf(_ keyData: Data, _ data: Data) -> Data {
        let key = SymmetricKey(data: keyData)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(mac)
    }

    private static func int32BE(_ v: UInt32) -> Data {
        var x = v.bigEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }

    private static func xorBytes(_ a: Data, _ b: Data) -> Data {
        Data(zip(a, b).map { $0 ^ $1 })
    }

    // MARK: - TCP 加密会话句柄

    final class LanConnection {
        private var fd: Int32 = -1
        private var key = Data(count: LanProtocol.pbkdf2KeyLen)
        private let lock = NSLock()
        private(set) var allowSecretConfig = false

        func connect(ip: String, port: Int, secret: String, deviceInfo: [String: Any]) throws {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { throw LanError("创建 socket 失败") }
            fd = sock
            do {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(port).bigEndian
                let resolved = inet_addr(ip)
                guard resolved != INADDR_NONE else { throw LanError("IP 无效: \(ip)") }
                addr.sin_addr.s_addr = resolved
                setRecvTimeout(LanProtocol.handshakeTimeoutMs)
                let c = withUnsafePointer(to: &addr) { aptr in
                    aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                        Darwin.connect(sock, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if c != 0 { throw LanError("连接失败: \(String(cString: strerror(errno)))") }

                if !secret.isEmpty {
                    guard let challenge = try? recvPlain(),
                          challenge["t"] as? String == "challenge"
                    else { throw LanError("握手失败：期望 challenge") }
                    let nonce = challenge["nonce"] as? String ?? ""
                    let mac = LanClient.hmacSha256(secret: secret, nonce: nonce)
                    try sendPlain(["t": "proof", "mac": mac])
                    guard let reply = try? recvPlain(),
                          reply["t"] as? String == "ok"
                    else { throw LanError("配对失败：密钥不正确") }
                } else {
                    guard let reply = try? recvPlain(),
                          reply["t"] as? String == "ok"
                    else { throw LanError("握手失败") }
                }
                key = LanClient.deriveKey(secret: secret)
                setRecvTimeout(LanProtocol.deviceConfirmTimeoutMs)
                let confirm = try request(cmd: "device_info", params: deviceInfo)
                guard confirm["ok"] as? Bool == true else {
                    let err = confirm["error"] as? String ?? ""
                    if err.contains("未知命令") {
                        throw LanError("电脑端版本过旧，不支持设备确认，请升级电脑端 OhMyMeme")
                    }
                    throw LanError(err.isEmpty ? "电脑端未确认设备信息" : err)
                }
                guard confirm["approved"] as? Bool == true else {
                    throw LanError("电脑端拒绝了本次连接")
                }
                allowSecretConfig = confirm["allow_secret_config"] as? Bool ?? false
                setRecvTimeout(LanProtocol.idleTimeoutMs)
            } catch {
                close()
                if let e = error as? LanError { throw e }
                throw LanError("连接失败：\(error)")
            }
        }

        /// 发送加密请求并等待加密响应（线程安全，阻塞）
        func request(cmd: String, params: [String: Any]? = nil) throws -> [String: Any] {
            guard fd >= 0 else { throw LanError("未连接") }
            var msg: [String: Any] = ["cmd": cmd]
            if let params {
                for (k, v) in params { msg[k] = v }
            }
            lock.lock(); defer { lock.unlock() }
            try sendFrame(msg)
            guard let resp = try? recvFrame() else { throw LanError("连接已断开") }
            return resp
        }

        func ping() -> Bool {
            (try? request(cmd: "ping"))?["ok"] as? Bool ?? false
        }

        func pullManifest() throws -> [String: Any] {
            let resp = try request(cmd: "pull_manifest")
            guard resp["ok"] as? Bool == true else {
                throw LanError(resp["error"] as? String ?? "获取清单失败")
            }
            guard let manifest = resp["manifest"] as? [String: Any] else {
                throw LanError("清单为空")
            }
            return manifest
        }

        func pushManifest(_ manifest: [String: Any]) throws {
            let resp = try request(cmd: "push_manifest", params: ["manifest": manifest])
            guard resp["ok"] as? Bool == true else {
                throw LanError(resp["error"] as? String ?? "推送清单失败")
            }
        }

        func pullFile(filename: String) throws -> Data {
            let resp = try request(cmd: "pull_file", params: ["filename": filename])
            guard resp["ok"] as? Bool == true else {
                throw LanError(resp["error"] as? String ?? "拉取文件失败")
            }
            guard let b64 = resp["data"] as? String,
                  let data = Data(base64Encoded: b64)
            else { throw LanError("文件数据解码失败") }
            return data
        }

        func pushFile(filename: String, data: Data) throws {
            let resp = try request(
                cmd: "push_file",
                params: ["filename": filename, "data": data.base64EncodedString()]
            )
            guard resp["ok"] as? Bool == true else {
                throw LanError(resp["error"] as? String ?? "推送文件失败")
            }
        }

        func getConfig() throws -> [String: Any] {
            let resp = try request(cmd: "get_config")
            guard resp["ok"] as? Bool == true else {
                throw LanError(resp["error"] as? String ?? "获取配置失败")
            }
            return resp
        }

        func sendConfig(_ config: [String: Any]) throws {
            let resp = try request(cmd: "send_config", params: ["config": config])
            guard resp["ok"] as? Bool == true else {
                throw LanError(resp["error"] as? String ?? "推送配置失败")
            }
        }

        func close() {
            if fd >= 0 {
                _ = Darwin.close(fd)
                fd = -1
            }
        }

        // MARK: - 帧读写

        private func setRecvTimeout(_ ms: Int) {
            guard fd >= 0 else { return }
            var tv = timeval(tv_sec: ms / 1000, tv_usec: Int32((ms % 1000) * 1000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }

        private func sendAll(_ data: Data) throws {
            guard fd >= 0 else { throw LanError("未连接") }
            try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                guard let base = ptr.baseAddress else { return }
                var total = 0
                while total < data.count {
                    let w = send(fd, base.advanced(by: total), data.count - total, 0)
                    if w <= 0 {
                        throw LanError("发送失败: \(String(cString: strerror(errno)))")
                    }
                    total += w
                }
            }
        }

        private func readExact(_ n: Int) throws -> Data {
            guard fd >= 0 else { throw LanError("未连接") }
            var buf = Data(count: n)
            var total = 0
            while total < n {
                let r = buf.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return recv(fd, base.advanced(by: total), n - total, 0)
                }
                if r == 0 { throw LanError("连接已关闭") }
                if r < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw LanError("读取超时") }
                    throw LanError("读取失败: \(String(cString: strerror(errno)))")
                }
                total += r
            }
            return buf
        }

        private func sendPlain(_ obj: [String: Any]) throws {
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else {
                throw LanError("JSON 序列化失败")
            }
            try sendAll(uint32BEData(data.count) + data)
        }

        private func recvPlain() throws -> [String: Any] {
            let ln = try readUInt32()
            guard ln <= LanProtocol.maxFrame else { throw LanError("帧过大") }
            let body = try readExact(Int(ln))
            guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                throw LanError("JSON 解析失败")
            }
            return obj
        }

        private func sendFrame(_ obj: [String: Any]) throws {
            guard let plain = try? JSONSerialization.data(withJSONObject: obj) else {
                throw LanError("JSON 序列化失败")
            }
            let combined = try LanClient.sealFrame(plain: plain, key: key)
            try sendAll(uint32BEData(combined.count) + combined)
        }

        private func recvFrame() throws -> [String: Any] {
            let ln = try readUInt32()
            guard ln <= LanProtocol.maxFrame, ln >= LanProtocol.ivLen + LanProtocol.tagLen else {
                throw LanError("帧长度非法")
            }
            let body = try readExact(Int(ln))
            let plain = try LanClient.unsealFrame(body, key: key)
            guard let obj = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
                throw LanError("JSON 解析失败")
            }
            return obj
        }

        private func readUInt32() throws -> UInt32 {
            let hdr = try readExact(4)
            let bytes = [UInt8](hdr)
            return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        }

        private func uint32BEData(_ v: Int) -> Data {
            let u = UInt32(v).bigEndian
            return withUnsafeBytes(of: u) { Data($0) }
        }
    }
}
